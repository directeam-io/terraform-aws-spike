import importlib.util
import pathlib
import unittest
from unittest import mock

SCRIPT_PATH = pathlib.Path(__file__).resolve().parent.parent / "scripts" / "update_existing_onboarding.py"
spec = importlib.util.spec_from_file_location("update_existing_onboarding", SCRIPT_PATH)
updater = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updater)

ACCOUNT_ID = "111111111111"
BASE_URL = "https://templates.example.com"
CHANGE_SET_ID = "arn:aws:cloudformation:us-east-1:111111111111:changeSet/spike/root"


def parameter(key, value):
    return {"ParameterKey": key, "ParameterValue": value}


class FakeAws:
    """Answers AWS CLI calls the way CloudFormation would for a single stack."""

    def __init__(self, stack, template_parameters, changes=None, change_set_status="CREATE_COMPLETE", reason=""):
        self.stack = stack
        self.template_parameters = template_parameters
        self.changes = changes or []
        self.change_set_status = change_set_status
        self.reason = reason
        self.calls = []

    def __call__(self, *args):
        self.calls.append(args)
        command = args[1]
        if command == "get-caller-identity":
            return {"Account": ACCOUNT_ID}
        if command == "describe-stacks":
            return {"Stacks": [self.stack]}
        if command == "get-template-summary":
            return {"Parameters": self.template_parameters, "Capabilities": ["CAPABILITY_NAMED_IAM"]}
        if command == "create-change-set":
            return {"Id": CHANGE_SET_ID}
        if command == "describe-change-set":
            return {"Status": self.change_set_status, "StatusReason": self.reason, "Changes": self.changes}
        if command == "execute-change-set":
            self.stack = {**self.stack, "StackStatus": "UPDATE_COMPLETE"}
            return {}
        if command in ("delete-change-set", "describe-stack-events"):
            return {}
        raise AssertionError(f"Unexpected AWS call: {args}")

    def commands(self):
        return [call[1] for call in self.calls]

    def call(self, command):
        return next(call for call in self.calls if call[1] == command)


def account_stack(version="v1.0.51", extra_parameters=()):
    return {
        "StackName": "DirecteamFinOpsReadOnlyAccess",
        "StackStatus": "UPDATE_COMPLETE",
        "Description": "Directeam FinOps Read Only Integration",
        "Parameters": [
            parameter("ExternalId", "external-123"),
            parameter("DirecteamId", "dtid-123"),
            parameter("TemplateVersion", version),
            *extra_parameters,
        ],
    }


TEMPLATE_PARAMETERS = [
    {"ParameterKey": "ExternalId"},
    {"ParameterKey": "DirecteamId"},
    {"ParameterKey": "TemplateVersion", "DefaultValue": "v1.0.51"},
    {"ParameterKey": "EnableCloudWatchLogsReadOnlyPolicy", "DefaultValue": "true"},
]


def run_update(fake, stack_name="DirecteamFinOpsReadOnlyAccess", version="v1.0.67"):
    with mock.patch.object(updater, "aws", fake), mock.patch.object(updater.time, "sleep"):
        updater.update(ACCOUNT_ID, stack_name, version, BASE_URL, timeout=60)


class BuildParametersTest(unittest.TestCase):
    def test_keeps_current_values_and_sets_version(self):
        parameters = updater.build_parameters(account_stack()["Parameters"], TEMPLATE_PARAMETERS, "v1.0.67")
        self.assertEqual(
            parameters,
            [
                {"ParameterKey": "ExternalId", "UsePreviousValue": True},
                {"ParameterKey": "DirecteamId", "UsePreviousValue": True},
                {"ParameterKey": "TemplateVersion", "ParameterValue": "v1.0.67"},
            ],
        )

    def test_refuses_parameters_the_new_template_dropped(self):
        current = account_stack(extra_parameters=[parameter("DenyApiGateway", "true")])["Parameters"]
        with self.assertRaisesRegex(updater.UpdateError, "DenyApiGateway"):
            updater.build_parameters(current, TEMPLATE_PARAMETERS, "v1.0.67")

    def test_refuses_new_required_parameters(self):
        template = [*TEMPLATE_PARAMETERS, {"ParameterKey": "OrganizationalRootID"}]
        with self.assertRaisesRegex(updater.UpdateError, "OrganizationalRootID"):
            updater.build_parameters(account_stack()["Parameters"], template, "v1.0.67")


class UpdateTest(unittest.TestCase):
    def test_updates_stack_through_change_set(self):
        changes = [{"ResourceChange": {
            "Action": "Modify",
            "LogicalResourceId": "DirecteamFinOpsReadOnlyAccess",
            "ResourceType": "AWS::IAM::Role",
            "Replacement": "False",
        }}]
        fake = FakeAws(account_stack(), TEMPLATE_PARAMETERS, changes)
        run_update(fake)

        self.assertIn("execute-change-set", fake.commands())
        create = fake.call("create-change-set")
        self.assertIn(f"{BASE_URL}/DirecteamFinOpsReadOnlyAccess/v1.0.67/DirecteamFinOpsReadOnlyAccess", create)
        self.assertIn("--include-nested-stacks", create)

    def test_stackset_stack_uses_stackset_template(self):
        stack = {**account_stack(), "StackName": "DirecteamFinOpsStackSet", "Description": "Deploy Directeam FinOps StackSet"}
        fake = FakeAws(stack, TEMPLATE_PARAMETERS)
        run_update(fake, stack_name="DirecteamFinOpsStackSet")
        self.assertIn(
            f"{BASE_URL}/DirecteamFinOpsStackSet/v1.0.67/DirecteamFinOpsStackSet", fake.call("create-change-set")
        )

    def test_current_version_is_a_no_op(self):
        fake = FakeAws(account_stack(version="v1.0.67"), TEMPLATE_PARAMETERS)
        run_update(fake)
        self.assertNotIn("create-change-set", fake.commands())

    def test_refuses_downgrade(self):
        fake = FakeAws(account_stack(version="v1.0.70"), TEMPLATE_PARAMETERS)
        with self.assertRaisesRegex(updater.UpdateError, "downgrade"):
            run_update(fake)
        self.assertNotIn("create-change-set", fake.commands())

    def test_change_set_without_changes_is_cleaned_up(self):
        fake = FakeAws(
            account_stack(), TEMPLATE_PARAMETERS, change_set_status="FAILED",
            reason="The submitted information didn't contain changes.",
        )
        run_update(fake)
        self.assertIn("delete-change-set", fake.commands())
        self.assertNotIn("execute-change-set", fake.commands())

    def test_refuses_replacing_core_resources(self):
        changes = [{"ResourceChange": {
            "Action": "Modify",
            "LogicalResourceId": "OUStackSet",
            "ResourceType": "AWS::CloudFormation::StackSet",
            "Replacement": "True",
        }}]
        fake = FakeAws(account_stack(), TEMPLATE_PARAMETERS, changes)
        with self.assertRaisesRegex(updater.UpdateError, "OUStackSet would be replaced"):
            run_update(fake)
        self.assertIn("delete-change-set", fake.commands())
        self.assertNotIn("execute-change-set", fake.commands())

    def test_refuses_creating_core_resources(self):
        changes = [{"ResourceChange": {
            "Action": "Add",
            "LogicalResourceId": "CurDataBucket",
            "ResourceType": "AWS::S3::Bucket",
        }}]
        fake = FakeAws(account_stack(), TEMPLATE_PARAMETERS, changes)
        with self.assertRaisesRegex(updater.UpdateError, "CurDataBucket would be created"):
            run_update(fake)
        self.assertNotIn("execute-change-set", fake.commands())

    def test_allows_policy_changes(self):
        changes = [
            {"ResourceChange": {"Action": "Add", "LogicalResourceId": "NewPolicy", "ResourceType": "AWS::IAM::ManagedPolicy"}},
            {"ResourceChange": {"Action": "Remove", "LogicalResourceId": "OldPolicy", "ResourceType": "AWS::IAM::ManagedPolicy"}},
        ]
        fake = FakeAws(account_stack(), TEMPLATE_PARAMETERS, changes)
        run_update(fake)
        self.assertIn("execute-change-set", fake.commands())

    def test_refuses_stackset_instances(self):
        fake = FakeAws(account_stack(), TEMPLATE_PARAMETERS)
        with self.assertRaisesRegex(updater.UpdateError, "StackSet instance"):
            run_update(fake, stack_name="StackSet-DirecteamFinOpsReadOnlyAccess-1234")
        self.assertEqual(fake.calls, [])

    def test_refuses_credentials_for_another_account(self):
        fake = FakeAws(account_stack(), TEMPLATE_PARAMETERS)
        with mock.patch.object(updater, "aws", fake), mock.patch.object(updater.time, "sleep"):
            with self.assertRaisesRegex(updater.UpdateError, "credentials belong to account"):
                updater.update("222222222222", "DirecteamFinOpsReadOnlyAccess", "v1.0.67", BASE_URL, timeout=60)


if __name__ == "__main__":
    unittest.main()
