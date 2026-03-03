# Generated cluster artifacts — do not commit

This directory holds cluster-specific artifacts produced by Ansible/RKE, for example:

- `kube_config_cluster.yaml` — kubeconfig with API server URL and credentials
- `k8s_cluster.rkestate` — RKE cluster state

These files are listed in the repository `.gitignore`. Do not commit them. Copy `kube_config_cluster.yaml` to your preferred location (e.g. `~/.kube/config`) for local use.
