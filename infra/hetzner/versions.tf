terraform {
  # 1.10 is the first OpenTofu release with native S3 state locking
  # (use_lockfile), which the remote state example below relies on.
  required_version = ">= 1.10.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "1.70.2"
    }
  }
}

# -----------------------------------------------------------------------------
# Remote state and encryption (example, disabled)
# -----------------------------------------------------------------------------
# Without a backend block OpenTofu keeps state in a local terraform.tfstate.
# That is acceptable for a throwaway lab, not for a shared environment.
#
# Treat state and saved plans as secrets:
#   - State holds the full infrastructure map: every public and private
#     address, the firewall rules and the admin public key.
#   - Any secret a resource handles, such as a private key it creates or a
#     password returned by an API, is written to state in plain text.
#     sensitive = true only hides a value in CLI output; it does not keep it
#     out of state.
#   - Saved plan files (tofu plan -out=...) contain the values of all input
#     variables, including hcloud_token.
#
# Requirements for shared use:
#   1. Store state in a private bucket with versioning enabled and access
#      limited to the operators and the pipeline identity of this cluster.
#   2. Encrypt state and plan files client side with the encryption block
#      below, so the object store and its operators only see ciphertext.
#   3. Pass object store credentials through the environment
#      (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY), never in this file.
#
# Native locking (use_lockfile) creates a lock object with a conditional write
# (If-None-Match). Not every S3-compatible store supports conditional writes,
# in particular on versioned buckets. Test that a second concurrent
# "tofu plan" is refused before relying on the lock.
#
# To enable: uncomment the variable and the terraform block, replace the
# CHANGE_ME values, export TF_VAR_state_passphrase, then run
# "tofu init -migrate-state". Losing the passphrase means losing the state.
#
# variable "state_passphrase" {
#   description = "Passphrase for client-side state and plan encryption (at least 16 characters). Set TF_VAR_state_passphrase."
#   type        = string
#   sensitive   = true
#
#   validation {
#     condition     = length(var.state_passphrase) >= 16
#     error_message = "state_passphrase must be at least 16 characters long."
#   }
# }
#
# terraform {
#   backend "s3" {
#     bucket = "CHANGE_ME-tofu-state"
#     key    = "infra/hetzner/reference/terraform.tfstate"
#     region = "CHANGE_ME" # region or location name expected by the object store
#
#     endpoints = {
#       s3 = "https://s3.example.com"
#     }
#
#     use_lockfile = true
#
#     # Settings for S3-compatible stores that are not AWS: there is no STS,
#     # IAM or EC2 metadata API, region names are provider specific, and some
#     # stores reject the newer S3 request checksums and virtual-host bucket
#     # addressing. Drop each one your object store does not need.
#     skip_credentials_validation = true
#     skip_region_validation      = true
#     skip_requesting_account_id  = true
#     skip_metadata_api_check     = true
#     skip_s3_checksum            = true
#     use_path_style              = true
#   }
#
#   encryption {
#     key_provider "pbkdf2" "state" {
#       passphrase = var.state_passphrase
#     }
#
#     method "aes_gcm" "state" {
#       keys = key_provider.pbkdf2.state
#     }
#
#     state {
#       method   = method.aes_gcm.state
#       enforced = true
#     }
#
#     plan {
#       method   = method.aes_gcm.state
#       enforced = true
#     }
#   }
# }
#
# Existing unencrypted state: for the first apply after enabling encryption,
# add `method "unencrypted" "migrate" {}` and a
# `fallback { method = method.unencrypted.migrate }` block inside state and
# plan, and set enforced = false. Remove both once the state is rewritten.
# Do not rename the key provider or method afterwards; the names are stored
# in the encrypted files.
