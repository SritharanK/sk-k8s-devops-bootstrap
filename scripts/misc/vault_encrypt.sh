#!/bin/bash
# -----------------------------------------------------------------------------
# Project: GitOps Kubernetes Platform Bootstrap
# Author : Sritharan K (https://www.skengineer.be)
# License: MIT
# -----------------------------------------------------------------------------

plaintext=$1

check_command() {
    if command -v "$1" &> /dev/null; then
        echo "$1 is installed."
    else
        echo "$1 is not installed."
    fi
}

check_command "ansible-vault"

ansible_vault encrypt_string "$plaintext"