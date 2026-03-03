# Secret Templates (Sealed Secrets)

This directory contains **annotated example templates** showing the shape of every
`SealedSecret` used by the platform. These files are never deployed directly —
they act as documentation and a starting point for the `kubeseal` workflow.

## Workflow

```
1. Copy the desired *.yaml.example file.
2. Fill in the base64-encoded values (or plain-text for kubeseal --raw).
3. Encrypt with kubeseal:
     kubeseal --controller-name sealed-secrets \
              --controller-namespace kube-system \
              --format yaml < my-secret.yaml > my-sealedsecret.yaml
4. Commit my-sealedsecret.yaml to the GitOps repo.
   The plain-text my-secret.yaml must NEVER be committed.
```

## Files

| File | Purpose |
|------|---------|
| `docker-registry-secret.yaml.example` | Image pull secret for the private Docker registry |
| `argocd-repo-secret.yaml.example` | Argo CD Git repository SSH credentials |
| `jenkins-credentials-secret.yaml.example` | Jenkins Git + Docker Hub credentials |
| `db-credentials-secret.yaml.example` | Database username/password per namespace |
