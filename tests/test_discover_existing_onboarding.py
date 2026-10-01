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
            stdout=json.dumps({"Stacks": [{"StackId": stack_id, "StackStatus": "CREATE_COMPLETE"}]}),
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
            },
        )


if __name__ == "__main__":
    unittest.main()
