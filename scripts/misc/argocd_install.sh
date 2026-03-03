#!/bin/bash
# -----------------------------------------------------------------------------
# Project: GitOps Kubernetes Platform Bootstrap
# Author : Sritharan K (https://www.skengineer.be)
# License: MIT
# -----------------------------------------------------------------------------

### Install Argocd
cd helmcharts/system-charts
helm upgrade --install argocd argo-cd -f argo-cd/values-lab.yaml -n argocd --create-namespace