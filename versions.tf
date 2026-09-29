terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }

    # Only used to discover Bedrock usage when enable_bedrock_invocation_logs is on without an explicit account map.
    external = {
      source  = "hashicorp/external"
      version = ">= 2.3"
    }
  }
}
