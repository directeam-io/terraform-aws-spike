import json

import boto3
import cfnresponse

servicequotas = boto3.client("service-quotas")
sns = boto3.client("sns", region_name="us-east-1")


def current_config():
    return servicequotas.get_auto_management_configuration()


def is_enabled(config):
    # OptInStatus is the enablement flag of the configuration AWS reports.
    return str(config.get("OptInStatus", "")).lower() == "enabled"


def apply(opt_in_type, exclusion_list):
    kwargs = {
        "OptInLevel": "ACCOUNT",
        "OptInType": opt_in_type,
    }
    # The API rejects an empty exclusion list; omit the argument entirely.
    if exclusion_list:
        kwargs["ExclusionList"] = exclusion_list
    if is_enabled(current_config()):
        servicequotas.update_auto_management(**kwargs)
    else:
        servicequotas.start_auto_management(**kwargs)


def publish_event(event, props, status, error=""):
    message = {
        "feature": "service_quotas_auto_management",
        "eventType": event["RequestType"],
        "directeamId": props["DirecteamId"],
        "accountId": props["AccountId"],
        "region": props["Region"],
        "optInType": props["OptInType"],
        "status": status,
        "stackVersion": props["StackVersion"],
    }
    if error:
        message["error"] = error[:180]
    sns.publish(
        TopicArn=props["NotificationTopicArn"],
        Message=json.dumps(message),
    )


def handler(event, context):
    props = event["ResourceProperties"]
    region = props["Region"]
    physical_id = event.get("PhysicalResourceId") or f"service-quotas-auto-management-{region}"
    try:
        exclusion_list = json.loads(props.get("ExclusionList") or "{}")
        if event["RequestType"] == "Delete":
            if physical_id.endswith("started"):
                servicequotas.stop_auto_management()
                publish_event(event, props, "removed")
            elif physical_id.endswith("adopted"):
                # An adopted (pre-existing) configuration is left enabled on removal.
                publish_event(event, props, "removed")
            else:
                # No suffix: the create never succeeded (failed create rolled
                # back). Publish nothing so the error status recorded by the
                # failed create stays visible.
                print(f"Delete {region}: skipped, create never succeeded")
            cfnresponse.send(event, context, cfnresponse.SUCCESS, {"Status": "removed"}, physical_id)
            return
        else:
            started_here = event["RequestType"] == "Create" and not is_enabled(current_config())
            apply(props["OptInType"], exclusion_list)
            status = "enabled"
            if event["RequestType"] == "Create":
                # The physical ID records whether this stack started auto
                # management or adopted an existing configuration, so Delete
                # only stops what this stack started.
                physical_id = f"service-quotas-auto-management-{region}-{'started' if started_here else 'adopted'}"
        publish_event(event, props, status)
        print(f"{event['RequestType']} {region}: {status}")
        cfnresponse.send(event, context, cfnresponse.SUCCESS, {"Status": status}, physical_id)
    except Exception as error:
        print(f"{event['RequestType']} {region} failed: {error!r}")
        try:
            publish_event(event, props, "error", str(error))
        except Exception as publish_error:
            print(f"Feature event publication failed: {publish_error!r}")
        # A failed delete would leave the stack stuck, so deletes always report success.
        result = cfnresponse.SUCCESS if event["RequestType"] == "Delete" else cfnresponse.FAILED
        cfnresponse.send(event, context, result, {"Status": "error"}, physical_id, reason=str(error)[:200])
