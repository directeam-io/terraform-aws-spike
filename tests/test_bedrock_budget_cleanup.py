import importlib.util
import json
import pathlib
import types
import unittest
from unittest import mock

from botocore.exceptions import ClientError

FUNCTION_PATH = pathlib.Path(__file__).resolve().parent.parent / "functions" / "bedrock_budget_cleanup.py"


class BedrockBudgetCleanupTest(unittest.TestCase):
    def setUp(self):
        self.iam = mock.Mock()
        self.lambda_client = mock.Mock()
        self.lambda_client.get_function_configuration.return_value = {"Timeout": 120}
        spec = importlib.util.spec_from_file_location("bedrock_budget_cleanup", FUNCTION_PATH)
        self.module = importlib.util.module_from_spec(spec)
        with mock.patch("boto3.client", side_effect=lambda service: self.iam if service == "iam" else self.lambda_client):
            spec.loader.exec_module(self.module)
        self.iam.get_paginator.side_effect = lambda op: types.SimpleNamespace(
            paginate=lambda: [{
                "Roles": [
                    {"RoleName": "app", "Path": "/apps/"},
                    {"RoleName": "DirecteamFinOpsReadOnlyAccess", "Path": "/"},
                ]
            }] if op == "list_roles" else [{"Users": [{"UserName": "ci", "Path": "/"}]}]
        )
        self.event = {
            "RequestType": "Delete", "ResponseURL": "https://example.invalid/response",
            "StackId": "stack", "RequestId": "request", "LogicalResourceId": "cleanup",
        }
        self.context = types.SimpleNamespace(log_stream_name="stream")

    def test_delete_removes_only_the_reserved_policy(self):
        with mock.patch.object(self.module.request, "urlopen") as urlopen, mock.patch.object(self.module.time, "sleep"):
            self.module.handler(self.event, self.context)
        self.iam.delete_role_policy.assert_called_once_with(RoleName="app", PolicyName=self.module.POLICY)
        self.iam.delete_user_policy.assert_called_once_with(UserName="ci", PolicyName=self.module.POLICY)
        self.lambda_client.put_function_concurrency.assert_called_once_with(FunctionName="DirecteamBedrockBudgetBlocker", ReservedConcurrentExecutions=0)
        self.assertEqual(json.loads(urlopen.call_args.args[0].data)["Status"], "SUCCESS")

    def test_cleanup_failure_fails_cloudformation_delete(self):
        self.iam.delete_role_policy.side_effect = ClientError(
            {"Error": {"Code": "AccessDenied", "Message": "denied"}}, "DeleteRolePolicy"
        )
        with mock.patch.object(self.module.request, "urlopen") as urlopen, mock.patch.object(self.module.time, "sleep"):
            self.module.handler(self.event, self.context)
        self.assertEqual(json.loads(urlopen.call_args.args[0].data)["Status"], "FAILED")
