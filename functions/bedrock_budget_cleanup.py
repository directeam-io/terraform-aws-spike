import json
import time
from urllib import request

import boto3
from botocore.exceptions import ClientError

iam = boto3.client("iam")
lambda_client = boto3.client("lambda")
POLICY = "DirecteamBedrockBudgetDeny"
BLOCKER = "DirecteamBedrockBudgetBlocker"


def handler(event, context):
    status = "SUCCESS"
    try:
        if event["RequestType"] == "Delete":
            timeout = lambda_client.get_function_configuration(FunctionName=BLOCKER)["Timeout"]
            if timeout > 600:
                raise RuntimeError("Blocker timeout is too long for safe cleanup")
            lambda_client.put_function_concurrency(FunctionName=BLOCKER, ReservedConcurrentExecutions=0)
            time.sleep(timeout + 10)
            for operation, key in (("list_roles", "Roles"), ("list_users", "Users")):
                for page in iam.get_paginator(operation).paginate():
                    for item in page[key]:
                        path = item["Path"].lower()
                        name = item["RoleName"] if key == "Roles" else item["UserName"]
                        if (path.startswith(("/aws-service-role/", "/aws-reserved/")) or
                            name.lower().startswith(("directeamfinops", "directeambedrockbudget", "awsreservedsso_")) or
                            name.lower() == "organizationaccountaccessrole"):
                            continue
                        try:
                            if key == "Roles":
                                iam.delete_role_policy(RoleName=name, PolicyName=POLICY)
                            else:
                                iam.delete_user_policy(UserName=name, PolicyName=POLICY)
                        except ClientError as exc:
                            if exc.response["Error"]["Code"] != "NoSuchEntity":
                                raise
    except Exception as exc:
        print(f"Bedrock budget policy cleanup failed: {exc}")
        status = "FAILED"
    body = json.dumps({
        "Status": status,
        "Reason": "See CloudWatch logs for cleanup details",
        "PhysicalResourceId": event.get("PhysicalResourceId") or context.log_stream_name,
        "StackId": event["StackId"],
        "RequestId": event["RequestId"],
        "LogicalResourceId": event["LogicalResourceId"],
        "Data": {},
    }).encode()
    req = request.Request(event["ResponseURL"], data=body, method="PUT", headers={"Content-Type": ""})
    with request.urlopen(req):
        pass
