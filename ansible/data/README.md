# Local cluster artifacts

This directory receives files that Ansible fetches from the cluster. Everything here except this README is
gitignored.

| File | Written by | Content |
|---|---|---|
| `kubeconfig-<cluster>.yaml` | `playbooks/site.yml` (rke2 role, bootstrap server) | Admin kubeconfig with the API address rewritten to the registration address or `rke2_api_endpoint`. Mode 0600. |

The kubeconfig holds cluster-admin credentials. Keep it on the operator machine, do not share it, and use it to
bootstrap GitOps and to create scoped access. Use it with:

```bash
export KUBECONFIG="$PWD/ansible/data/kubeconfig-lab.yaml"
```
