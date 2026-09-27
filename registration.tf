resource "aws_cloudformation_stack" "registration" {
  #checkov:skip=CKV_AWS_124:The stack only holds a notification custom resource; stack event notifications add nothing.
  count = var.notify_spike ? 1 : 0

  region = local.home_region
  name   = local.registration_stack_name

  template_body = jsonencode({
    AWSTemplateFormatVersion = "2010-09-09"
    Description              = "Notifies Spike that onboarding finished (terraform-spike-aws-onboarding v${local.module_version})"

    Resources = {
      SpikeRegistration = {
        Type = "AWS::CloudFormation::CustomResource"
        Properties = {
          ServiceToken   = var.notification_topic_arn
          ServiceTimeout = var.notification_timeout
          stackArn       = { Ref = "AWS::StackId" }
          directeamId    = var.directeam_id
          state          = "finish"
          stackName      = local.role_name
          stackVersion   = "v${local.module_version}"
          deploymentTool = "terraform"
          deploymentMode = var.deployment_mode
          roleArn        = try(aws_iam_role.spike[0].arn, "")
          curBucketName  = try(aws_s3_bucket.cur[0].id, "")
          stackSetName   = try(aws_cloudformation_stack_set.spike[0].name, "")
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
