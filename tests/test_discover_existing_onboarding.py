import importlib.util
import io
import json
import pathlib
import subprocess
import sys
import unittest
from unittest import mock

SCRIPT_PATH = pathlib.Path(__file__).resolve().parent.parent / "scripts" / "discover_existing_onboarding.py"
spec = importlib.util.spec_from_file_location("discover_existing_onboarding", SCRIPT_PATH)
discovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(discovery)


class ExistingOnboardingDiscoveryTest(unittest.TestCase):
    def test_missing_stack_returns_none(self):
        completed = subprocess.CompletedProcess(
            args=[],
            returncode=255,
            stdout="",
            stderr="ValidationError: Stack with id DirecteamFinOpsReadOnlyAccess does not exist",
        )
        with mock.patch.object(discovery.subprocess, "run", return_value=completed):
            self.assertIsNone(discovery.describe_stack("DirecteamFinOpsReadOnlyAccess"))

    def test_access_error_fails_instead_of_creating_duplicates(self):
        completed = subprocess.CompletedProcess(
            args=[],
            returncode=254,
            stdout="",
            stderr="AccessDenied: not authorized to perform cloudformation:DescribeStacks",
        )
        with mock.patch.object(discovery.subprocess, "run", return_value=completed):
            with self.assertRaises(discovery.DiscoveryError):
                discovery.describe_stack("DirecteamFinOpsReadOnlyAccess")

    def test_success_reports_existing_stack(self):
        stack_id = "arn:aws:cloudformation:us-east-1:111111111111:stack/DirecteamFinOpsReadOnlyAccess/id"
        completed = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=json.dumps({
                "Stacks": [{
                    "StackId": stack_id,
                    "StackStatus": "CREATE_COMPLETE",
                    "Parameters": [
                        {"ParameterKey": "ExternalId", "ParameterValue": "external-123"},
                        {"ParameterKey": "DirecteamId", "ParameterValue": "dtid-123"},
                        {"ParameterKey": "TemplateVersion", "ParameterValue": "v1.0.51"},
                    ],
                }]
            }),
            stderr="",
        )
        stdin = io.StringIO(json.dumps({"deployment_mode": "account", "account_id": "111111111111"}))
        stdout = io.StringIO()
        with (
            mock.patch.object(discovery.subprocess, "run", return_value=completed),
            mock.patch.object(sys, "stdin", stdin),
            mock.patch.object(sys, "stdout", stdout),
        ):
            discovery.main()
        self.assertEqual(
            json.loads(stdout.getvalue()),
            {
                "exists": "true",
                "stack_name": "DirecteamFinOpsReadOnlyAccess",
                "stack_status": "CREATE_COMPLETE",
                "template_version": "v1.0.51",
                "identity_found": "true",
                "identity_stack_name": "DirecteamFinOpsReadOnlyAccess",
                "external_id": "external-123",
                "directeam_id": "dtid-123",
            },
        )

    def test_stackset_instance_reports_existing_stack(self):
        stack_name = "StackSet-DirecteamFinOpsReadOnlyAccess-instance-id"
        missing_base = subprocess.CompletedProcess(
            args=[],
            returncode=255,
            stdout="",
            stderr="ValidationError: Stack with id DirecteamFinOpsReadOnlyAccess does not exist",
        )
        stackset_instances = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=json.dumps({"StackSummaries": [{"StackName": stack_name}]}),
            stderr="",
        )
        stackset_instance = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=json.dumps({
                "Stacks": [{
                    "StackId": f"arn:aws:cloudformation:us-east-1:111111111111:stack/{stack_name}/id",
                    "StackStatus": "CREATE_COMPLETE",
                    "Parameters": [
                        {"ParameterKey": "ExternalId", "ParameterValue": "external-789"},
                        {"ParameterKey": "DirecteamId", "ParameterValue": "dtid-789"},
                    ],
                }]
            }),
            stderr="",
        )
        stdin = io.StringIO(json.dumps({"deployment_mode": "account", "account_id": "111111111111"}))
        stdout = io.StringIO()
        with (
            mock.patch.object(
                discovery.subprocess,
                "run",
                side_effect=[missing_base, stackset_instances, stackset_instance],
            ),
            mock.patch.object(sys, "stdin", stdin),
            mock.patch.object(sys, "stdout", stdout),
        ):
            discovery.main()
        self.assertEqual(
            json.loads(stdout.getvalue()),
            {
                "exists": "true",
                "stack_name": stack_name,
                "stack_status": "CREATE_COMPLETE",
                "template_version": "",
                "identity_found": "true",
                "identity_stack_name": stack_name,
                "external_id": "external-789",
                "directeam_id": "dtid-789",
            },
        )

    def test_bootstrap_stack_supplies_identity_without_claiming_base_ownership(self):
        missing_base = subprocess.CompletedProcess(
            args=[],
            returncode=255,
            stdout="",
            stderr="ValidationError: Stack with id DirecteamFinOpsReadOnlyAccess does not exist",
        )
        bootstrap_id = "arn:aws:cloudformation:us-east-1:111111111111:stack/DirecteamTerraformBootstrap/id"
        bootstrap = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=json.dumps({
                "Stacks": [{
                    "StackId": bootstrap_id,
                    "StackStatus": "CREATE_COMPLETE",
                    "Parameters": [
                        {"ParameterKey": "ExternalId", "ParameterValue": "external-456"},
                        {"ParameterKey": "DirecteamId", "ParameterValue": "dtid-456"},
                    ],
                }]
            }),
            stderr="",
        )
        stdin = io.StringIO(json.dumps({"deployment_mode": "account", "account_id": "111111111111"}))
        stdout = io.StringIO()
        no_stackset_instance = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=json.dumps({"StackSummaries": []}),
            stderr="",
        )
        with (
            mock.patch.object(discovery.subprocess, "run", side_effect=[missing_base, no_stackset_instance, bootstrap]),
            mock.patch.object(sys, "stdin", stdin),
            mock.patch.object(sys, "stdout", stdout),
        ):
            discovery.main()
        self.assertEqual(
            json.loads(stdout.getvalue()),
            {
                "exists": "false",
                "stack_name": "",
                "stack_status": "",
                "template_version": "",
                "identity_found": "true",
                "identity_stack_name": "DirecteamTerraformBootstrap",
                "external_id": "external-456",
                "directeam_id": "dtid-456",
            },
        )


if __name__ == "__main__":
    unittest.main()
