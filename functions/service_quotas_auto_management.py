import json

import boto3
import cfnresponse

servicequotas = boto3.client("service-quotas")
sns = boto3.client("sns", region_name="us-east-1")


def current_config():
    return servicequotas.get_auto_management_configuration()


def is_enabled(config):
    return str(config.get("OptInStatus", "")).lower() == "enabled"


def apply(opt_in_type, exclusion_list):
    kwargs = {"OptInType": opt_in_type}
    # An empty list is rejected.
    if exclusion_list:
        kwargs["ExclusionList"] = exclusion_list
    if is_enabled(current_config()):
        # Update rejects OptInLevel.
        servicequotas.update_auto_management(**kwargs)
    else:
        servicequotas.start_auto_management(OptInLevel="ACCOUNT", **kwargs)


def unchanged(config, opt_in_type, exclusion_list):
    # The API returns {"QuotaCode": ...} objects.
    def codes(exclusions):
        return {
            key: {item["QuotaCode"] if isinstance(item, dict) else item for item in items}
            for key, items in (exclusions or {}).items()
        }

    return (
        is_enabled(config)
        and config.get("OptInType") == opt_in_type
        and not config.get("NotificationArn")
        and codes(config.get("ExclusionList")) == codes(exclusion_list)
    )


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
    sns.publish(TopicArn=props["NotificationTopicArn"], Message=json.dumps(message))


def handler(event, context):
    props = event["ResourceProperties"]
    region = props["Region"]
    request = event["RequestType"]
    physical_id = event.get("PhysicalResourceId") or f"service-quotas-auto-management-{region}"
    try:
        exclusion_list = json.loads(props.get("ExclusionList") or "{}")
        if request == "Delete":
            status = "removed"
            if physical_id.endswith("started"):
                # Stop only if still the module's.
                if unchanged(current_config(), props["OptInType"], exclusion_list):
                    servicequotas.stop_auto_management()
                else:
                    status = "skipped-customer-modified"
            if physical_id.endswith(("started", "adopted")):
                publish_event(event, props, "removed")
                print(f"Delete {region}: {status}")
            else:  # failed create
                print(f"Delete {region}: skipped, create never succeeded")
            cfnresponse.send(event, context, cfnresponse.SUCCESS, {"Status": status}, physical_id)
            return
        # Never change an existing configuration ("adopted").
        skip = (request == "Create" and is_enabled(current_config())) or (
            request == "Update" and physical_id.endswith("adopted")
        )
        status = "skipped-existing-configuration"
        if not skip:
            apply(props["OptInType"], exclusion_list)
            status = "enabled"
        if request == "Create":
            physical_id = f"service-quotas-auto-management-{region}-{'adopted' if skip else 'started'}"
        publish_event(event, props, "enabled")
        print(f"{request} {region}: {status}")
        cfnresponse.send(event, context, cfnresponse.SUCCESS, {"Status": status}, physical_id)
    except Exception as error:
        print(f"{request} {region} failed: {error!r}")
        try:
            publish_event(event, props, "error", str(error))
        except Exception as publish_error:
            print(f"Publish failed: {publish_error!r}")
        # Deletes always succeed, or the stack gets stuck.
        result = cfnresponse.SUCCESS if request == "Delete" else cfnresponse.FAILED
        cfnresponse.send(event, context, result, {"Status": "error"}, physical_id, reason=str(error)[:200])
