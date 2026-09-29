import boto3
import cfnresponse

bedrock = boto3.client("bedrock")
s3 = boto3.resource("s3")

DATA_DELIVERY_FLAGS = (
    "textDataDeliveryEnabled",
    "imageDataDeliveryEnabled",
    "embeddingDataDeliveryEnabled",
    "videoDataDeliveryEnabled",
)


def current_config():
    return bedrock.get_model_invocation_logging_configuration().get("loggingConfig") or {}


def points_to(config, bucket):
    return (config.get("s3Config") or {}).get("bucketName") == bucket


def enable(bucket, key_prefix):
    # Metadata only: prompts, responses and embeddings are never delivered.
    supported = bedrock.meta.service_model.shape_for("LoggingConfig").members
    config = {"s3Config": {"bucketName": bucket, "keyPrefix": key_prefix}}
    config.update({flag: False for flag in DATA_DELIVERY_FLAGS if flag in supported})
    bedrock.put_model_invocation_logging_configuration(loggingConfig=config)


def handler(event, context):
    props = event["ResourceProperties"]
    bucket = props["BucketName"]
    physical_id = event.get("PhysicalResourceId") or "bedrock-invocation-logging-" + bucket
    try:
        config = current_config()
        if event["RequestType"] == "Delete":
            if points_to(config, bucket):
                bedrock.delete_model_invocation_logging_configuration()
            s3.Bucket(bucket).objects.all().delete()
            status = "removed"
        elif config and not points_to(config, bucket):
            # Never replace logging the account owner configured themselves.
            status = "skipped-existing-configuration"
        else:
            enable(bucket, props["KeyPrefix"])
            status = "enabled"
        print(f"{event['RequestType']} {bucket}: {status}")
        cfnresponse.send(event, context, cfnresponse.SUCCESS, {"Status": status}, physical_id)
    except Exception as error:
        print(f"{event['RequestType']} {bucket} failed: {error!r}")
        # A failed delete would leave the stack stuck, so deletes always report success.
        result = cfnresponse.SUCCESS if event["RequestType"] == "Delete" else cfnresponse.FAILED
        cfnresponse.send(event, context, result, {"Status": "error"}, physical_id, reason=str(error)[:200])
