import json
import re

import boto3
from botocore.exceptions import ClientError

iam = boto3.client("iam")
POLICY = "DirecteamBedrockBudgetDeny"
ACTIONS = [f"bedrock:{action}" for action in (
    "InvokeModel", "InvokeModelWithResponseStream", "CreateModelInvocationJob",
    "InvokeAgent", "InvokeInlineAgent", "InvokeFlow", "RetrieveAndGenerate", "CallWithBearerToken",
)] + ["bedrock-mantle:CreateInference", "bedrock-mantle:CallWithBearerToken"]
ARN = re.compile(r"^arn:([a-z0-9-]+):iam::([0-9]{12}):(role|user)/([A-Za-z0-9+=,.@_/-]+)$")


def principal(arn, partition, account):
    match = ARN.fullmatch(arn) if isinstance(arn, str) else None
    if not match:
        return None
    arn_partition, arn_account, kind, path = match.groups()
    name = path.rsplit("/", 1)[-1]
    if (arn_partition != partition or arn_account != account or not name or
        path.lower().startswith(("aws-service-role/", "aws-reserved/")) or
        name.lower().startswith(("directeamfinops", "directeambedrockbudget", "awsreservedsso_")) or
        name.lower() == "organizationaccountaccessrole"):
        return None
    return kind, name


def handler(event, context):
    if event.get("action") != "reconcile" or not isinstance(event.get("blocks"), list) or not isinstance(event.get("releases"), list):
        raise ValueError("Invalid")
    partition, account = context.invoked_function_arn.split(":")[1], context.invoked_function_arn.split(":")[4]
    results, blocks, releases = [], event["blocks"], event["releases"]
    block_arns = [block.get("principal_arn") for block in blocks if isinstance(block, dict)]
    for release, block in [(False, block) for block in blocks] + [(True, {"principal_arn": arn}) for arn in releases]:
        if not isinstance(block, dict):
            results.append({"status": "not_enforceable", "message": "Invalid block"})
            continue
        arn = block.get("principal_arn", "")
        result = {"principal_arn": arn}
        target = principal(arn, partition, account)
        if (not target or (arn in block_arns and arn in releases) or
            (not release and (block_arns.count(arn) != 1 or block.get("deny_all") is not True or block.get("tags") != {}))):
            results.append({**result, "status": "not_enforceable", "message": "Unsupported"})
            continue
        kind, name = target
        try:
            if release:
                if kind == "role":
                    iam.delete_role_policy(RoleName=name, PolicyName=POLICY)
                else:
                    iam.delete_user_policy(UserName=name, PolicyName=POLICY)
                results.append({**result, "status": "released"})
                continue
            document = {"Version": "2012-10-17", "Statement": [{"Sid": "DenyAll", "Effect": "Deny", "Action": ACTIONS, "Resource": "*"}]}
            try:
                current = (iam.get_role_policy(RoleName=name, PolicyName=POLICY) if kind == "role"
                           else iam.get_user_policy(UserName=name, PolicyName=POLICY))["PolicyDocument"]
            except ClientError as exc:
                if exc.response["Error"]["Code"] != "NoSuchEntity":
                    raise
                current = None
            if current == document:
                status = "unchanged"
            else:
                policy = json.dumps(document, separators=(",", ":"))
                if kind == "role":
                    iam.put_role_policy(RoleName=name, PolicyName=POLICY, PolicyDocument=policy)
                else:
                    iam.put_user_policy(UserName=name, PolicyName=POLICY, PolicyDocument=policy)
                status = "applied"
            results.append({**result, "status": status})
        except ClientError as exc:
            if release and exc.response["Error"]["Code"] == "NoSuchEntity":
                results.append({**result, "status": "released"})
            else:
                results.append({**result, "status": "error", "message": str(exc)})
        except Exception as exc:
            results.append({**result, "status": "error", "message": str(exc)})
    return {"results": results}
