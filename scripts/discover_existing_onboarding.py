#!/usr/bin/env python3
"""Detect an existing Directeam CloudFormation onboarding stack for Terraform."""

import json
import subprocess
import sys


BASE_STACK_NAMES = {
    "organization": "DirecteamFinOpsStackSet",
    "account": "DirecteamFinOpsReadOnlyAccess",
}
BOOTSTRAP_STACK_NAME = "DirecteamTerraformBootstrap"
SUCCESS_STATUSES = {
    "CREATE_COMPLETE",
    "UPDATE_COMPLETE",
    "UPDATE_ROLLBACK_COMPLETE",
    "IMPORT_COMPLETE",
}


class DiscoveryError(Exception):
    pass


def describe_stack(stack_name):
    try:
        completed = subprocess.run(
            [
                "aws",
                "cloudformation",
                "describe-stacks",
                "--region",
                "us-east-1",
                "--stack-name",
                stack_name,
                "--output",
                "json",
            ],
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
        )
    except FileNotFoundError as error:
        raise DiscoveryError("The AWS CLI is required to detect existing onboarding stacks.") from error
    except subprocess.TimeoutExpired as error:
        raise DiscoveryError(f"CloudFormation lookup for {stack_name} timed out.") from error

    if completed.returncode == 0:
        stacks = json.loads(completed.stdout or "{}").get("Stacks") or []
        if len(stacks) != 1:
            raise DiscoveryError(f"Expected one CloudFormation stack named {stack_name}, found {len(stacks)}.")
        return stacks[0]

    stderr = completed.stderr.strip()
    if "does not exist" in stderr or "ValidationError" in stderr and stack_name in stderr:
        return None
    raise DiscoveryError(f"CloudFormation lookup for {stack_name} failed: {stderr}")


def validate_stack(stack, stack_name, account_id):
    status = str(stack.get("StackStatus") or "")
    if status not in SUCCESS_STATUSES:
        raise DiscoveryError(f"CloudFormation stack {stack_name} exists in status {status}; resolve it before running Terraform.")
    stack_account_id = str(stack.get("StackId") or "").split(":")[4]
    if stack_account_id != account_id:
        raise DiscoveryError(f"CloudFormation lookup used account {stack_account_id}, but Terraform is targeting {account_id}.")
    parameters = {item["ParameterKey"]: item.get("ParameterValue", "") for item in stack.get("Parameters") or []}
    external_id = str(parameters.get("ExternalId") or "")
    directeam_id = str(parameters.get("DirecteamId") or "")
    if not external_id or not directeam_id:
        raise DiscoveryError(f"CloudFormation stack {stack_name} must contain ExternalId and DirecteamId parameters.")
    return status, external_id, directeam_id


def main():
    query = json.load(sys.stdin)
    deployment_mode = query.get("deployment_mode")
    account_id = query.get("account_id")
    if deployment_mode not in BASE_STACK_NAMES:
        raise DiscoveryError("deployment_mode must be organization or account.")
    if not isinstance(account_id, str) or len(account_id) != 12 or not account_id.isdigit():
        raise DiscoveryError("account_id must be a 12-digit AWS account ID.")

    base_stack_name = BASE_STACK_NAMES[deployment_mode]
    base_stack = describe_stack(base_stack_name)
    identity_stack_name = base_stack_name
    identity_stack = base_stack
    if identity_stack is None:
        identity_stack_name = BOOTSTRAP_STACK_NAME
        identity_stack = describe_stack(identity_stack_name)

    if identity_stack is None:
        result = {
            "exists": "false",
            "stack_name": "",
            "stack_status": "",
            "identity_found": "false",
            "identity_stack_name": "",
            "external_id": "",
            "directeam_id": "",
        }
    else:
        status, external_id, directeam_id = validate_stack(identity_stack, identity_stack_name, account_id)
        result = {
            "exists": "true" if base_stack is not None else "false",
            "stack_name": base_stack_name if base_stack is not None else "",
            "stack_status": status if base_stack is not None else "",
            "identity_found": "true",
            "identity_stack_name": identity_stack_name,
            "external_id": external_id,
            "directeam_id": directeam_id,
        }
    json.dump(result, sys.stdout)


if __name__ == "__main__":
    try:
        main()
    except (DiscoveryError, json.JSONDecodeError) as error:
        print(f"Existing onboarding discovery failed: {error}", file=sys.stderr)
        sys.exit(1)
