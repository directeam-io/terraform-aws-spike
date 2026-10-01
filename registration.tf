locals {
  bedrock_registration_resources = {
    for region in local.local_bedrock_logs_regions : "BedrockLogs${replace(title(region), "-", "")}" => {
      Type = "AWS::CloudFormation::CustomResource"
      Properties = {
        ServiceToken   = var.notification_topic_arn
        ServiceTimeout = var.notification_timeout
        feature        = "bedrock_invocation_logs"
        eventStatus    = "enabled"
        directeamId    = local.directeam_id
        accountId      = local.account_id
        region         = region
        bucketName     = "${local.bedrock_logs_bucket_prefix}-${local.account_id}-${region}"
        stackVersion   = "v${local.module_version}"
      }
    }
  }
}

resource "aws_cloudformation_stack" "registration" {
  #checkov:skip=CKV_AWS_124:The stack only holds a notification custom resource; stack event notifications add nothing.
  count = var.notify_spike && local.manage_base_onboarding ? 1 : 0

  region = local.home_region
  name   = local.registration_stack_name

  template_body = jsonencode({
    AWSTemplateFormatVersion = "2010-09-09"
    Description              = "Notifies Spike that onboarding finished (terraform-aws-spike v${local.module_version})"

    Resources = {
      SpikeRegistration = {
        Type = "AWS::CloudFormation::CustomResource"
        Properties = {
          ServiceToken   = var.notification_topic_arn
          ServiceTimeout = var.notification_timeout
          stackArn       = { Ref = "AWS::StackId" }
          directeamId    = local.directeam_id
          state          = "finish"
          stackName      = local.role_name
          stackVersion   = "v${local.module_version}"
        }
      }
    }
  })

  tags = local.tags

  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }

  depends_on = [
    aws_iam_role_policy_attachment.spike,
    aws_cloudformation_stack_set_instance.spike,
    aws_bcmdataexports_export.cur,
  ]
}

resource "aws_cloudformation_stack" "bedrock_registration" {
  #checkov:skip=CKV_AWS_124:The stack only holds notification custom resources; stack event notifications add nothing.
  count = var.notify_spike && length(local.local_bedrock_logs_regions) > 0 ? 1 : 0

  region = local.home_region
  name   = local.bedrock_registration_stack_name

  template_body = jsonencode({
    AWSTemplateFormatVersion = "2010-09-09"
    Description              = "Registers Directeam Bedrock invocation logging regions (v${local.module_version})"
    Resources                = local.bedrock_registration_resources
  })

  tags = local.tags

  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }

  depends_on = [
    aws_bedrock_model_invocation_logging_configuration.spike,
    aws_iam_role_policy.bedrock_logs_read,
  ]
}
