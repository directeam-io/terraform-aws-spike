import importlib.util
import json
import pathlib
import types
import unittest
from unittest import mock

from botocore.exceptions import ClientError

FUNCTION_PATH = pathlib.Path(__file__).resolve().parent.parent / "functions" / "bedrock_budget_blocker.py"
ROLE = "arn:aws:iam::111111111111:role/application"
CONTEXT = types.SimpleNamespace(invoked_function_arn="arn:aws:lambda:us-east-1:111111111111:function:blocker")


class BedrockBudgetBlockerTest(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("bedrock_budget_blocker", FUNCTION_PATH)
        self.module = importlib.util.module_from_spec(spec)
        self.iam = mock.Mock()
        with mock.patch("boto3.client", return_value=self.iam):
            spec.loader.exec_module(self.module)
        self.missing = ClientError({"Error": {"Code": "NoSuchEntity", "Message": "not found"}}, "GetRolePolicy")

    def test_applies_and_releases_principal_policy(self):
        self.iam.get_role_policy.side_effect = self.missing
        result = self.module.handler({"action": "reconcile", "blocks": [{"principal_arn": ROLE, "deny_all": True, "tags": {}}], "releases": []}, CONTEXT)
        self.assertEqual(result["results"][0]["status"], "applied")
        policy = json.loads(self.iam.put_role_policy.call_args.kwargs["PolicyDocument"])
        self.assertEqual(policy["Statement"][0]["Effect"], "Deny")
        self.assertIn("bedrock:InvokeModel", policy["Statement"][0]["Action"])
        self.assertIn("bedrock-mantle:CreateInference", policy["Statement"][0]["Action"])
        self.assertIn("bedrock-mantle:CallWithBearerToken", policy["Statement"][0]["Action"])
        self.iam.get_role_policy.side_effect = None
        self.iam.get_role_policy.return_value = {"PolicyDocument": policy}
        result = self.module.handler({"action": "reconcile", "blocks": [{"principal_arn": ROLE, "deny_all": True, "tags": {}}], "releases": []}, CONTEXT)
        self.assertEqual(result["results"][0]["status"], "unchanged")
        self.iam.put_role_policy.assert_called_once()
        result = self.module.handler({"action": "reconcile", "blocks": [], "releases": [ROLE]}, CONTEXT)
        self.assertEqual(result["results"][0]["status"], "released")
        self.iam.delete_role_policy.side_effect = self.missing
        result = self.module.handler({"action": "reconcile", "blocks": [], "releases": [ROLE]}, CONTEXT)
        self.assertEqual(result["results"][0]["status"], "released")

    def test_rejects_protected_foreign_and_tag_scoped_blocks(self):
        principals = [
            "arn:aws:iam::222222222222:role/application",
            "arn:aws:iam::111111111111:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_Admin",
            "arn:aws:iam::111111111111:role/path/DirecteamFinOpsReadOnlyAccess",
            "arn:aws:iam::111111111111:role/AWSReservedSSO_Admin",
            "arn:aws:sts::111111111111:assumed-role/application/session",
        ]
        blocks = [{"principal_arn": arn, "deny_all": True, "tags": {}} for arn in principals]
        blocks.append({"principal_arn": ROLE, "deny_all": False, "tags": {"application": ["x"]}})
        result = self.module.handler({"action": "reconcile", "blocks": blocks, "releases": []}, CONTEXT)
        self.assertTrue(all(item["status"] == "not_enforceable" for item in result["results"]))
        self.iam.put_role_policy.assert_not_called()

    def test_existing_policy_is_updated_to_deny_mantle(self):
        previous_actions = [action for action in self.module.ACTIONS if not action.startswith("bedrock-mantle:")]
        self.iam.get_role_policy.return_value = {"PolicyDocument": {
            "Version": "2012-10-17",
            "Statement": [{"Sid": "DenyAll", "Effect": "Deny", "Action": previous_actions, "Resource": "*"}],
        }}
        result = self.module.handler({"action": "reconcile", "blocks": [{"principal_arn": ROLE, "deny_all": True, "tags": {}}], "releases": []}, CONTEXT)
        self.assertEqual(result["results"][0]["status"], "applied")
        policy = json.loads(self.iam.put_role_policy.call_args.kwargs["PolicyDocument"])
        self.assertIn("bedrock-mantle:CreateInference", policy["Statement"][0]["Action"])
        self.assertIn("bedrock-mantle:CallWithBearerToken", policy["Statement"][0]["Action"])

    def test_inline_source_fits_cloudformation(self):
        self.assertLessEqual(FUNCTION_PATH.stat().st_size, 51200)
