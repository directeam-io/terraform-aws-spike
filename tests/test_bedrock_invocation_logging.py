import importlib.util
import pathlib
import sys
import types
import unittest
from unittest import mock

FUNCTION_PATH = pathlib.Path(__file__).resolve().parent.parent / "functions" / "bedrock_invocation_logging.py"
BUCKET = "dt-bedrock-logs-111111111111-us-east-1"
LEGACY_SDK_FLAGS = ("textDataDeliveryEnabled", "imageDataDeliveryEnabled", "embeddingDataDeliveryEnabled")
CURRENT_SDK_FLAGS = LEGACY_SDK_FLAGS + ("videoDataDeliveryEnabled",)


def load_function(bedrock):
    cfnresponse = types.SimpleNamespace(SUCCESS="SUCCESS", FAILED="FAILED", send=mock.Mock())
    s3 = mock.Mock()
    boto3 = types.SimpleNamespace(client=lambda name: bedrock, resource=lambda name: s3)
    with mock.patch.dict(sys.modules, {"boto3": boto3, "cfnresponse": cfnresponse}):
        spec = importlib.util.spec_from_file_location("bedrock_invocation_logging", FUNCTION_PATH)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    return module, cfnresponse, s3


def bedrock_client(existing_config=None, supported_flags=LEGACY_SDK_FLAGS):
    client = mock.Mock()
    client.get_model_invocation_logging_configuration.return_value = (
        {"loggingConfig": existing_config} if existing_config is not None else {}
    )
    client.meta.service_model.shape_for.return_value.members = {flag: None for flag in supported_flags}
    return client


def event(request_type):
    return {
        "RequestType": request_type,
        "ResourceProperties": {"BucketName": BUCKET, "KeyPrefix": "invocation-logs"},
    }


class BedrockInvocationLoggingTest(unittest.TestCase):
    def sent(self, cfnresponse):
        args, kwargs = cfnresponse.send.call_args
        return args[2], args[3]["Status"], kwargs

    def test_create_enables_metadata_only_logging(self):
        bedrock = bedrock_client()
        function, cfnresponse, _ = load_function(bedrock)

        function.handler(event("Create"), None)

        bedrock.put_model_invocation_logging_configuration.assert_called_once_with(
            loggingConfig={
                "s3Config": {"bucketName": BUCKET, "keyPrefix": "invocation-logs"},
                "textDataDeliveryEnabled": False,
                "imageDataDeliveryEnabled": False,
                "embeddingDataDeliveryEnabled": False,
            }
        )
        self.assertEqual(self.sent(cfnresponse)[:2], ("SUCCESS", "enabled"))

    def test_create_includes_video_flag_when_the_sdk_supports_it(self):
        bedrock = bedrock_client(supported_flags=CURRENT_SDK_FLAGS)
        function, _, _ = load_function(bedrock)

        function.handler(event("Create"), None)

        config = bedrock.put_model_invocation_logging_configuration.call_args.kwargs["loggingConfig"]
        self.assertIs(config["videoDataDeliveryEnabled"], False)

    def test_create_keeps_existing_customer_configuration(self):
        bedrock = bedrock_client(existing_config={"s3Config": {"bucketName": "customer-owned-bucket"}})
        function, cfnresponse, _ = load_function(bedrock)

        function.handler(event("Create"), None)

        bedrock.put_model_invocation_logging_configuration.assert_not_called()
        self.assertEqual(self.sent(cfnresponse)[:2], ("SUCCESS", "skipped-existing-configuration"))

    def test_create_keeps_existing_cloudwatch_only_configuration(self):
        bedrock = bedrock_client(existing_config={"cloudWatchConfig": {"logGroupName": "customer-group"}})
        function, cfnresponse, _ = load_function(bedrock)

        function.handler(event("Create"), None)

        bedrock.put_model_invocation_logging_configuration.assert_not_called()
        self.assertEqual(self.sent(cfnresponse)[1], "skipped-existing-configuration")

    def test_update_reapplies_own_configuration(self):
        bedrock = bedrock_client(existing_config={"s3Config": {"bucketName": BUCKET}})
        function, cfnresponse, _ = load_function(bedrock)

        function.handler(event("Update"), None)

        bedrock.put_model_invocation_logging_configuration.assert_called_once()
        self.assertEqual(self.sent(cfnresponse)[1], "enabled")

    def test_delete_removes_own_configuration_and_empties_bucket(self):
        bedrock = bedrock_client(existing_config={"s3Config": {"bucketName": BUCKET}})
        function, cfnresponse, s3 = load_function(bedrock)

        function.handler(event("Delete"), None)

        bedrock.delete_model_invocation_logging_configuration.assert_called_once()
        s3.Bucket.assert_called_once_with(BUCKET)
        s3.Bucket.return_value.objects.all.return_value.delete.assert_called_once()
        self.assertEqual(self.sent(cfnresponse)[:2], ("SUCCESS", "removed"))

    def test_delete_leaves_customer_configuration_in_place(self):
        bedrock = bedrock_client(existing_config={"s3Config": {"bucketName": "customer-owned-bucket"}})
        function, _, _ = load_function(bedrock)

        function.handler(event("Delete"), None)

        bedrock.delete_model_invocation_logging_configuration.assert_not_called()

    def test_delete_reports_success_even_when_cleanup_fails(self):
        bedrock = bedrock_client()
        bedrock.get_model_invocation_logging_configuration.side_effect = RuntimeError("throttled")
        function, cfnresponse, _ = load_function(bedrock)

        function.handler(event("Delete"), None)

        self.assertEqual(self.sent(cfnresponse)[0], "SUCCESS")

    def test_create_reports_failure_on_error(self):
        bedrock = bedrock_client()
        bedrock.put_model_invocation_logging_configuration.side_effect = RuntimeError("AccessDenied")
        function, cfnresponse, _ = load_function(bedrock)

        function.handler(event("Create"), None)

        status, _, kwargs = self.sent(cfnresponse)
        self.assertEqual(status, "FAILED")
        self.assertIn("AccessDenied", kwargs["reason"])


if __name__ == "__main__":
    unittest.main()
