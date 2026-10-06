locals {
  template_version_pattern = "^v(\\d+)\\.(\\d+)\\.(\\d+)$"

  # Versions as comparable numbers: v1.2.3 -> 1000002000003.
  spike_template_version_number = sum([
    for index, part in regex(local.template_version_pattern, local.spike_template_version) : tonumber(part) * pow(1000000, 2 - index)
  ])
  existing_template_version_number = try(sum([
    for index, part in regex(local.template_version_pattern, local.existing_onboarding_template_version) : tonumber(part) * pow(1000000, 2 - index)
  ]), 0)
}

# Updates the CloudFormation-owned onboarding stack in place. Terraform never owns the stack, so removing this resource
# (or turning update_spike_stack off) leaves the stack untouched.
resource "terraform_data" "spike_stack_update" {
  count = local.update_spike_stack ? 1 : 0

  triggers_replace = {
    stack_name       = local.existing_onboarding_stack_name
    template_version = local.spike_template_version
  }

  provisioner "local-exec" {
    command = "python3 \"${path.module}/scripts/update_existing_onboarding.py\""

    environment = {
      SPIKE_ACCOUNT_ID        = local.account_id
      SPIKE_STACK_NAME        = local.existing_onboarding_stack_name
      SPIKE_TEMPLATE_VERSION  = local.spike_template_version
      SPIKE_TEMPLATE_BASE_URL = var.spike_template_base_url
    }
  }

  lifecycle {
    precondition {
      condition     = var.spike_template_base_url != null
      error_message = "update_spike_stack requires spike_template_base_url. Ask Directeam for the Spike template URL."
    }

    precondition {
      condition     = !startswith(local.existing_onboarding_stack_name, "StackSet-")
      error_message = "${local.existing_onboarding_stack_name} is a stack instance of a CloudFormation StackSet and can only be updated through that StackSet. Set update_spike_stack = false for this account."
    }

    precondition {
      condition     = local.existing_template_version_number <= local.spike_template_version_number
      error_message = "${local.existing_onboarding_stack_name} is on ${local.existing_onboarding_template_version}, newer than ${local.spike_template_version} released with this module version. Upgrade the module or set update_spike_stack = false."
    }
  }
}
