import importlib.util
import json
import pathlib
import sys
import types
import unittest
from unittest import mock

FUNCTION_PATH = pathlib.Path(__file__).resolve().parent.parent / "functions" / "service_quotas_auto_management.py"


def load_function(servicequotas):
    cfnresponse = types.SimpleNamespace(SUCCESS="SUCCESS", FAILED="FAILED", send=mock.Mock())
    sns = mock.Mock()
    boto3 = types.SimpleNamespace(
        client=lambda name, **kwargs: servicequotas if name == "service-quotas" else sns,
    )
    with mock.patch.dict(sys.modules, {"boto3": boto3, "cfnresponse": cfnresponse}):
        spec = importlib.util.spec_from_file_location("service_quotas_auto_management", FUNCTION_PATH)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    return module, cfnresponse, sns


def servicequotas_client(opt_in_status="Disabled", **config):
    client = mock.Mock()
    client.get_auto_management_configuration.return_value = {"OptInStatus": opt_in_status, **config}

    def update(**kwargs):
        # Like the real API (found live): UpdateAutoManagement has no OptInLevel parameter.
        if "OptInLevel" in kwargs:
            raise ValueError('Unknown parameter in input: "OptInLevel"')

    client.update_auto_management.side_effect = update
    return client


def api_exclusions(exclusions):
    """Exclusions in the shape GetAutoManagementConfiguration returns (checked live): objects, not plain codes."""
    return {
        service: [{"QuotaCode": code, "QuotaName": f"Quota {code}"} for code in codes]
        for service, codes in exclusions.items()
    }


def modules_configuration(**overrides):
    """The configuration the module itself applies for the test event, as the API reports it."""
    return {
        "opt_in_status": "ENABLED",
        "OptInType": "NotifyOnly",
        "ExclusionList": api_exclusions({"dynamodb": ["L-F98FE922"]}),
        **overrides,
    }


STARTED = "service-quotas-auto-management-us-east-1-started"
ADOPTED = "service-quotas-auto-management-us-east-1-adopted"


def event(request_type, physical_resource_id=None):
    return {
        "RequestType": request_type,
        "PhysicalResourceId": physical_resource_id,
        "ResourceProperties": {
            "NotificationTopicArn": "arn:aws:sns:us-east-1:250260913666:onboarding",
            "DirecteamId": "dtid-test",
            "OptInType": "NotifyOnly",
            "ExclusionList": '{"dynamodb": ["L-F98FE922"]}',
            "AccountId": "111111111111",
            "Region": "us-east-1",
            "StackVersion": "v1.4.0",
        },
    }


class ServiceQuotasAutoManagementTest(unittest.TestCase):
    def sent(self, cfnresponse):
        args, kwargs = cfnresponse.send.call_args
        return args[2], args[3]["Status"], args[4]

    def published(self, sns):
        return json.loads(sns.publish.call_args.kwargs["Message"])

    def test_create_starts_auto_management_when_disabled(self):
        servicequotas = servicequotas_client(opt_in_status="Disabled")
        function, cfnresponse, sns = load_function(servicequotas)

        function.handler(event("Create"), None)

        servicequotas.start_auto_management.assert_called_once_with(
            OptInLevel="ACCOUNT",
            OptInType="NotifyOnly",
            ExclusionList={"dynamodb": ["L-F98FE922"]},
        )
        self.assertEqual(self.sent(cfnresponse)[:2], ("SUCCESS", "enabled"))
        self.assertTrue(self.sent(cfnresponse)[2].endswith("started"))
        published = self.published(sns)
        self.assertEqual(published["feature"], "service_quotas_auto_management")
        self.assertEqual(published["status"], "enabled")

    def test_create_skips_existing_configuration(self):
        servicequotas = servicequotas_client(opt_in_status="Enabled", OptInType="NotifyAndAdjust")
        function, cfnresponse, sns = load_function(servicequotas)

        function.handler(event("Create"), None)

        servicequotas.start_auto_management.assert_not_called()
        servicequotas.update_auto_management.assert_not_called()
        servicequotas.stop_auto_management.assert_not_called()
        self.assertEqual(self.sent(cfnresponse)[:2], ("SUCCESS", "skipped-existing-configuration"))
        self.assertTrue(self.sent(cfnresponse)[2].endswith("adopted"))
        self.assertEqual(self.published(sns)["status"], "enabled")

    def test_update_reapplies_configuration_of_started_stack(self):
        servicequotas = servicequotas_client(opt_in_status="Enabled")
        function, cfnresponse, sns = load_function(servicequotas)

        function.handler(event("Update", physical_resource_id=STARTED), None)

        # The real API rejects OptInLevel on update (found live), so it must not be sent.
        servicequotas.update_auto_management.assert_called_once_with(
            OptInType="NotifyOnly",
            ExclusionList={"dynamodb": ["L-F98FE922"]},
        )
        servicequotas.start_auto_management.assert_not_called()
        self.assertEqual(self.sent(cfnresponse), ("SUCCESS", "enabled", STARTED))
        self.assertEqual(self.published(sns)["status"], "enabled")

    def test_update_restarts_started_stack_that_was_turned_off(self):
        servicequotas = servicequotas_client(opt_in_status="Disabled")
        function, cfnresponse, _ = load_function(servicequotas)

        function.handler(event("Update", physical_resource_id=STARTED), None)

        servicequotas.start_auto_management.assert_called_once_with(
            OptInLevel="ACCOUNT",
            OptInType="NotifyOnly",
            ExclusionList={"dynamodb": ["L-F98FE922"]},
        )
        servicequotas.update_auto_management.assert_not_called()
        self.assertEqual(self.sent(cfnresponse), ("SUCCESS", "enabled", STARTED))

    def test_update_skips_adopted(self):
        servicequotas = servicequotas_client(opt_in_status="Enabled", OptInType="NotifyAndAdjust")
        function, cfnresponse, sns = load_function(servicequotas)

        function.handler(event("Update", physical_resource_id=ADOPTED), None)

        servicequotas.start_auto_management.assert_not_called()
        servicequotas.update_auto_management.assert_not_called()
        servicequotas.stop_auto_management.assert_not_called()
        self.assertEqual(self.sent(cfnresponse), ("SUCCESS", "skipped-existing-configuration", ADOPTED))
        self.assertEqual(self.published(sns)["status"], "enabled")

    def test_delete_stops_only_what_the_stack_started(self):
        servicequotas = servicequotas_client(**modules_configuration())
        function, cfnresponse, sns = load_function(servicequotas)

        function.handler(event("Delete", physical_resource_id=STARTED), None)

        servicequotas.stop_auto_management.assert_called_once()
        self.assertEqual(self.sent(cfnresponse), ("SUCCESS", "removed", STARTED))
        self.assertEqual(self.published(sns)["status"], "removed")

    def test_delete_compares_exclusion_lists_as_sets(self):
        servicequotas = servicequotas_client(
            **modules_configuration(ExclusionList=api_exclusions({"dynamodb": ["L-B", "L-A"]}))
        )
        function, cfnresponse, _ = load_function(servicequotas)
        delete = event("Delete", physical_resource_id=STARTED)
        delete["ResourceProperties"]["ExclusionList"] = '{"dynamodb": ["L-A", "L-B"]}'

        function.handler(delete, None)

        servicequotas.stop_auto_management.assert_called_once()
        self.assertEqual(self.sent(cfnresponse)[1], "removed")

    def test_delete_accepts_plain_code_exclusions_too(self):
        servicequotas = servicequotas_client(**modules_configuration(ExclusionList={"dynamodb": ["L-F98FE922"]}))
        function, cfnresponse, _ = load_function(servicequotas)

        function.handler(event("Delete", physical_resource_id=STARTED), None)

        servicequotas.stop_auto_management.assert_called_once()
        self.assertEqual(self.sent(cfnresponse)[1], "removed")

    def test_delete_stops_when_no_exclusions_on_either_side(self):
        servicequotas = servicequotas_client(**modules_configuration(ExclusionList={}))
        function, cfnresponse, _ = load_function(servicequotas)
        delete = event("Delete", physical_resource_id=STARTED)
        delete["ResourceProperties"]["ExclusionList"] = "{}"

        function.handler(delete, None)

        servicequotas.stop_auto_management.assert_called_once()

    def test_delete_skips_customer_modified(self):
        changes = {
            "different OptInType": {"OptInType": "NotifyAndAdjust"},
            "extra exclusion": {
                "ExclusionList": api_exclusions({"dynamodb": ["L-F98FE922"], "ec2": ["L-1216C47A"]})
            },
            "different exclusion": {"ExclusionList": api_exclusions({"dynamodb": ["L-OTHER"]})},
            "NotificationArn set": {"NotificationArn": "arn:aws:notifications::111111111111:configuration/x"},
            "exclusions removed": {"ExclusionList": {}},
        }
        for name, change in changes.items():
            with self.subTest(name):
                servicequotas = servicequotas_client(**modules_configuration(**change))
                function, cfnresponse, sns = load_function(servicequotas)

                function.handler(event("Delete", physical_resource_id=STARTED), None)

                servicequotas.stop_auto_management.assert_not_called()
                self.assertEqual(self.sent(cfnresponse), ("SUCCESS", "skipped-customer-modified", STARTED))
                self.assertEqual(self.published(sns)["status"], "removed")

    def test_delete_skips_started_stack_that_is_already_off(self):
        servicequotas = servicequotas_client(opt_in_status="Disabled")
        function, cfnresponse, sns = load_function(servicequotas)

        function.handler(event("Delete", physical_resource_id=STARTED), None)

        servicequotas.stop_auto_management.assert_not_called()
        self.assertEqual(self.sent(cfnresponse)[:2], ("SUCCESS", "skipped-customer-modified"))
        self.assertEqual(self.published(sns)["status"], "removed")

    def test_delete_leaves_adopted_configuration_enabled(self):
        servicequotas = servicequotas_client(**modules_configuration())
        function, cfnresponse, sns = load_function(servicequotas)

        function.handler(event("Delete", physical_resource_id=ADOPTED), None)

        servicequotas.stop_auto_management.assert_not_called()
        self.assertEqual(self.sent(cfnresponse)[1], "removed")
        self.assertEqual(self.published(sns)["status"], "removed")

    def test_delete_after_failed_create_publishes_nothing(self):
        # A failed create rolls back with a Delete whose physical ID carries
        # no suffix; the error status it recorded must stay in place.
        servicequotas = servicequotas_client(opt_in_status="Enabled")
        function, cfnresponse, sns = load_function(servicequotas)

        function.handler(
            event("Delete", physical_resource_id="service-quotas-auto-management-us-east-1"),
            None,
        )

        servicequotas.stop_auto_management.assert_not_called()
        sns.publish.assert_not_called()
        self.assertEqual(self.sent(cfnresponse)[0], "SUCCESS")

    def test_failure_publishes_error_and_fails_create(self):
        servicequotas = servicequotas_client(opt_in_status="Disabled")
        servicequotas.start_auto_management.side_effect = RuntimeError("OptInType not available")
        function, cfnresponse, sns = load_function(servicequotas)

        function.handler(event("Create"), None)

        self.assertEqual(self.sent(cfnresponse)[0], "FAILED")
        published = self.published(sns)
        self.assertEqual(published["status"], "error")
        self.assertTrue(published["error"])

    def test_source_fits_inline_zipfile_limit(self):
        self.assertLessEqual(len(FUNCTION_PATH.read_text()), 4096)


if __name__ == "__main__":
    unittest.main()
