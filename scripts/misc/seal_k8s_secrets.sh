#!/bin/bash
# -----------------------------------------------------------------------------
# Project: GitOps Kubernetes Platform Bootstrap
# Author : Sritharan K (https://www.skengineer.be)
# License: MIT
# -----------------------------------------------------------------------------
# Seal Kubernetes secrets with kubeseal (Sealed Secrets).
# Reads plain YAML Secret manifests from helmcharts/system-charts/argocd-config/unseal/
# and writes encrypted SealedSecret manifests to .../sealed/. Only the sealed files
# should be committed to Git.
#
# PREREQUISITES:
#   - KUBECONFIG set and cluster reachable.
#   - kubeseal installed (e.g. brew install kubeseal).
#   - Sealed Secrets controller running in the cluster (deployed via Argo CD
#     toolchain sealed-secret-controller).
#
# USAGE: From repo root, run:  ./scripts/misc/seal_k8s_secrets.sh
#        Or: make seal-secrets
# -----------------------------------------------------------------------------

[ -n "$KUBECONFIG" ] || { echo "Set KUBECONFIG to your kubeconfig path."; exit 1; }
UNSEAL_DIR="helmcharts/system-charts/argocd-config/unseal"
SEALED_DIR="helmcharts/system-charts/argocd-config/sealed"

# Create sealed directory if it does not exist
mkdir -p $SEALED_DIR

# Fetch the Sealed Secrets controller's public key (needed to encrypt)
SEALED_SECRETS_CONTROLLER="sealed-secrets-controller"
SEALED_SECRETS_NAMESPACE="kube-system"
kubeseal --fetch-cert --controller-name $SEALED_SECRETS_CONTROLLER --controller-namespace $SEALED_SECRETS_NAMESPACE > /tmp/pub-cert.pem

# Encrypt each unsealed YAML file and write to sealed/
for file in $UNSEAL_DIR/*.yaml; do
  # Get the filename without the directory
  filename=$(basename $file)
  
  # Encrypt the file using kubeseal
  kubeseal --format=yaml --cert /tmp/pub-cert.pem < $file > $SEALED_DIR/$filename
  
  # Check if the encryption was successful
  if [ $? -eq 0 ]; then
    echo "Successfully sealed $file to $SEALED_DIR/$filename"
  else
    echo "Failed to seal $file"
  fi
done

# Cleanup temporary cert
rm /tmp/pub-cert.pem

echo "All secrets have been sealed and placed in $SEALED_DIR"
