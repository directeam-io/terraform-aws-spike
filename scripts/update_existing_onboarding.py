#!/usr/bin/env python3
"""Update an existing Directeam CloudFormation onboarding stack to the template version pinned by the module.

Runs from a Terraform local-exec provisioner with the same AWS credentials as the AWS CLI. Configuration comes from
environment variables:
  SPIKE_ACCOUNT_ID        account Terraform is deploying to
  SPIKE_STACK_NAME        stack to update (DirecteamFinOpsStackSet or DirecteamFinOpsReadOnlyAccess)
  SPIKE_TEMPLATE_VERSION  target version, e.g. v1.0.67
  SPIKE_TEMPLATE_BASE_URL base URL of the Spike templates, provided by Directeam
  SPIKE_UPDATE_TIMEOUT    optional, seconds to wait for the update (default 7200)

The update goes through a change set. It is refused, and nothing changes, when it would remove or replace anything
other than a managed policy, or add a role, StackSet, nested stack, bucket, or CUR export. Those changes mean the stack
is too old to update in place and the upgrade has to be planned with Directeam.
"""

import json
import os
import re
import subprocess
import sys
import time

REGION = "us-east-1"
VERSION_PATTERN = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
STABLE_STATUSES = {"CREATE_COMPLETE", "UPDATE_COMPLETE", "UPDATE_ROLLBACK_COMPLETE", "IMPORT_COMPLETE"}
CAPABILITIES = ["CAPABILITY_IAM", "CAPABILITY_NAMED_IAM"]
TEMPLATES = {
    "stackset": "DirecteamFinOpsStackSet/{version}/DirecteamFinOpsStackSet",
    "management": "DirecteamFinOpsMgmtReadOnlyAccess/{version}/DirecteamFinOpsMgmtReadOnlyAccess",
    "account": "DirecteamFinOpsReadOnlyAccess/{version}/DirecteamFinOpsReadOnlyAccess",
}
# Resources whose creation means the template changed shape, so an in-place update would collide with existing ones.
PROTECTED_ADD_TYPES = {
    "AWS::IAM::Role",
    "AWS::CloudFormation::StackSet",
    "AWS::CloudFormation::Stack",
    "AWS::S3::Bucket",
    "AWS::BCMDataExports::Export",
}
REPLACEABLE_TYPES = {"AWS::IAM::ManagedPolicy"}
NO_CHANGES_REASONS = ("didn't contain changes", "No updates are to be performed")
POLL_SECONDS = 15


class UpdateError(Exception):
    pass


def aws(*args):
    try:
        completed = subprocess.run(
            ["aws", *args, "--region", REGION, "--output", "json"],
            capture_output=True,
            text=True,
            timeout=300,
            check=False,
        )
    except FileNotFoundError as error:
        raise UpdateError("The AWS CLI is required to update the Spike CloudFormation stack.") from error
    except subprocess.TimeoutExpired as error:
        raise UpdateError(f"'aws {' '.join(args[:2])}' timed out.") from error
    if completed.returncode != 0:
        raise UpdateError(f"'aws {' '.join(args[:2])}' failed: {completed.stderr.strip()}")
    return json.loads(completed.stdout or "{}")


def parse_version(value):
    match = VERSION_PATTERN.match(value or "")
    return tuple(int(part) for part in match.groups()) if match else None


def template_kind(stack_name, description):
    if stack_name == "DirecteamFinOpsStackSet":
        return "stackset"
    if "Management Read Only" in (description or ""):
        return "management"
    return "account"


def build_parameters(current, template_parameters, version):
    """Keep every current value, set TemplateVersion, and let new optional parameters take their defaults."""
    current_keys = {item["ParameterKey"] for item in current}
    template_keys = {item["ParameterKey"] for item in template_parameters}

    dropped = sorted(current_keys - template_keys)
    if dropped:
        raise UpdateError(
            f"The stack uses parameters that {version} no longer has: {', '.join(dropped)}. Contact Directeam to plan "
            "this upgrade."
        )

    parameters = []
    missing = []
    for item in template_parameters:
        key = item["ParameterKey"]
        if key == "TemplateVersion":
            parameters.append({"ParameterKey": key, "ParameterValue": version})
        elif key in current_keys:
            parameters.append({"ParameterKey": key, "UsePreviousValue": True})
        elif "DefaultValue" not in item:
            missing.append(key)
    if missing:
        raise UpdateError(
            f"{version} requires parameters the stack doesn't have: {', '.join(sorted(missing))}. Contact Directeam to "
            "plan this upgrade."
        )
    return parameters


def blocked_reason(change):
    action = change.get("Action")
    resource_type = change.get("ResourceType", "")
    replacement = change.get("Replacement")
    if action == "Remove" and resource_type not in REPLACEABLE_TYPES:
        return "would be deleted"
    if action == "Modify" and replacement in ("True", "Conditional") and resource_type not in REPLACEABLE_TYPES:
        return "would be replaced"
    if action == "Add" and resource_type in PROTECTED_ADD_TYPES:
        return "would be created"
    return None


def change_set_changes(change_set_id, stack_label):
    """Yield (stack, resource change) for a change set and every nested stack change set."""
    token = None
    while True:
        args = ["cloudformation", "describe-change-set", "--change-set-name", change_set_id]
        if token:
            args += ["--next-token", token]
        page = aws(*args)
        for change in page.get("Changes") or []:
            resource_change = change.get("ResourceChange") or {}
            yield stack_label, resource_change
            nested_id = resource_change.get("ChangeSetId")
            if nested_id and nested_id != change_set_id:
                yield from change_set_changes(nested_id, f"{stack_label}/{resource_change.get('LogicalResourceId')}")
        token = page.get("NextToken")
        if not token:
            return


def wait_for_change_set(change_set_id, deadline):
    while True:
        change_set = aws("cloudformation", "describe-change-set", "--change-set-name", change_set_id)
        status = change_set.get("Status")
        if status == "CREATE_COMPLETE":
            return True
        if status == "FAILED":
            reason = change_set.get("StatusReason") or ""
            if any(text in reason for text in NO_CHANGES_REASONS):
                return False
            raise UpdateError(f"Creating the change set failed: {reason}")
        if time.monotonic() > deadline:
            raise UpdateError("Timed out waiting for the change set to be created.")
        time.sleep(POLL_SECONDS)


def failure_events(stack_name):
    events = aws("cloudformation", "describe-stack-events", "--stack-name", stack_name, "--max-items", "50")
    reasons = [
        f"{event.get('LogicalResourceId')}: {event.get('ResourceStatusReason')}"
        for event in events.get("StackEvents") or []
        if str(event.get("ResourceStatus", "")).endswith("FAILED") and event.get("ResourceStatusReason")
    ]
    return reasons[:5]


def wait_for_stack(stack_name, deadline):
    while True:
        status = describe_stack(stack_name)["StackStatus"]
        if not status.endswith("_IN_PROGRESS"):
            return status
        if time.monotonic() > deadline:
            raise UpdateError(f"Timed out waiting for {stack_name} to finish updating (status {status}).")
        time.sleep(POLL_SECONDS)


def describe_stack(stack_name):
    stacks = aws("cloudformation", "describe-stacks", "--stack-name", stack_name).get("Stacks") or []
    if len(stacks) != 1:
        raise UpdateError(f"Expected one CloudFormation stack named {stack_name}, found {len(stacks)}.")
    return stacks[0]


def update(account_id, stack_name, version, base_url, timeout):
    if stack_name.startswith("StackSet-"):
        raise UpdateError(f"{stack_name} is a StackSet instance and can only be updated through its StackSet.")
    target = parse_version(version)
    if target is None:
        raise UpdateError(f"Template version {version!r} must look like v1.2.3.")

    caller_account = aws("sts", "get-caller-identity")["Account"]
    if caller_account != account_id:
        raise UpdateError(
            f"The AWS CLI credentials belong to account {caller_account}, but Terraform is deploying to {account_id}."
        )

    stack = describe_stack(stack_name)
    status = stack.get("StackStatus")
    if status not in STABLE_STATUSES:
        raise UpdateError(f"{stack_name} is in status {status}; resolve it before updating.")

    current_parameters = stack.get("Parameters") or []
    current_version = next(
        (item.get("ParameterValue") for item in current_parameters if item["ParameterKey"] == "TemplateVersion"), ""
    )
    current = parse_version(current_version)
    if current == target:
        print(f"{stack_name} is already on {version}.")
        return
    if current is not None and current > target:
        raise UpdateError(f"{stack_name} is on {current_version}, newer than {version}; refusing to downgrade.")

    template_url = f"{base_url}/{TEMPLATES[template_kind(stack_name, stack.get('Description'))].format(version=version)}"
    summary = aws("cloudformation", "get-template-summary", "--template-url", template_url)
    parameters = build_parameters(current_parameters, summary.get("Parameters") or [], version)
    capabilities = sorted(set(CAPABILITIES) | set(summary.get("Capabilities") or []))

    deadline = time.monotonic() + timeout
    change_set_name = f"spike-{version.replace('.', '-')}-{int(time.time())}"
    change_set_id = aws(
        "cloudformation",
        "create-change-set",
        "--stack-name",
        stack_name,
        "--change-set-name",
        change_set_name,
        "--change-set-type",
        "UPDATE",
        "--template-url",
        template_url,
        "--parameters",
        json.dumps(parameters),
        "--capabilities",
        *capabilities,
        "--include-nested-stacks",
        "--description",
        f"Update Spike onboarding from {current_version or 'unversioned'} to {version}",
    )["Id"]

    try:
        if not wait_for_change_set(change_set_id, deadline):
            print(f"{stack_name} has no changes for {version}.")
            aws("cloudformation", "delete-change-set", "--change-set-name", change_set_id)
            return

        blocked = []
        for label, change in change_set_changes(change_set_id, stack_name):
            reason = blocked_reason(change)
            line = f"  {label}: {change.get('Action')} {change.get('LogicalResourceId')} ({change.get('ResourceType')})"
            print(line + (f" - {reason}" if reason else ""))
            if reason:
                blocked.append(f"{label}/{change.get('LogicalResourceId')} {reason}")
        if blocked:
            raise UpdateError(
                f"Updating {stack_name} from {current_version or 'unversioned'} to {version} is not an in-place upgrade: "
                f"{'; '.join(blocked)}. Nothing was changed. Contact Directeam to plan this upgrade."
            )
    except UpdateError:
        aws("cloudformation", "delete-change-set", "--change-set-name", change_set_id)
        raise

    print(f"Updating {stack_name} from {current_version or 'unversioned'} to {version}.")
    aws("cloudformation", "execute-change-set", "--change-set-name", change_set_id)
    final_status = wait_for_stack(stack_name, deadline)
    if final_status != "UPDATE_COMPLETE":
        details = "; ".join(failure_events(stack_name))
        raise UpdateError(f"Updating {stack_name} ended in {final_status}. {details}".strip())
    print(f"{stack_name} is now on {version}.")


def main():
    try:
        update(
            account_id=os.environ["SPIKE_ACCOUNT_ID"],
            stack_name=os.environ["SPIKE_STACK_NAME"],
            version=os.environ["SPIKE_TEMPLATE_VERSION"],
            base_url=os.environ["SPIKE_TEMPLATE_BASE_URL"].rstrip("/"),
            timeout=int(os.environ.get("SPIKE_UPDATE_TIMEOUT", "7200")),
        )
    except KeyError as error:
        print(f"Spike stack update failed: missing environment variable {error}", file=sys.stderr)
        sys.exit(1)
    except UpdateError as error:
        print(f"Spike stack update failed: {error}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
