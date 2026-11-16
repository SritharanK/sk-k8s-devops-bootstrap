# Reference cluster secrets

The reference profile uses External Secrets Operator with OpenBao. Sealed Secrets is disabled in `clusters/reference/cluster.yaml` (`toolchains.sealed-secrets.enabled: false`), so nothing in this directory would be decrypted. Keep it empty; bootstrap secrets are SOPS files applied through `REPO_SECRET_FILE`, see clusters/README.md.
