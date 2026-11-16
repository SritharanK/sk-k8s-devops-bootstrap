---
status: accepted
date: 2026-11-16
decision-makers: platform maintainers
---

# RKE2 as the only Kubernetes provisioner

This record explains why the provisioning layer installs RKE2 and no other distribution. It is for operators who build the `reference` profile and for reviewers who compare distributions.

## Context and problem statement

The platform provisions its own nodes with Ansible and then hands the cluster to Argo CD. The provisioning layer must produce a supported, hardened and highly available cluster on general-purpose Linux hosts (Ubuntu 24.04, Debian 12 and 13, Rocky 9), including sites without internet access. Every additional provisioner doubles the Ansible code, the tests and the upgrade procedures.

Which Kubernetes distribution should the Ansible layer install?

## Decision drivers

- A supported lifecycle that follows upstream Kubernetes minor releases, with a documented upgrade path.
- Few moving parts on the node: an embedded container runtime and an embedded etcd, so the node role installs no Docker engine and no external datastore.
- A CIS hardening profile that the distribution itself supports.
- High availability with several servers behind one fixed registration address.
- Air-gap installation from release artifacts.
- Easy to drive from Ansible: one binary, one configuration file per node, idempotent restarts.

## Considered options

- RKE2
- RKE1
- k3s
- kubeadm
- Talos Linux

## Decision outcome

Chosen option: "RKE2", because it is the only supported option that meets every driver through a single configuration file per node, without replacing the host operating system.

The `rke2` Ansible role installs servers and agents from the inventory. The first server initialises the cluster; the other servers and the agents join through the registration address. The cluster file `clusters/<name>/cluster.yaml` sets the exact RKE2 version (`rke2.version`), the CNI (`canal`, `calico` or `cilium`), the registration address (`rke2.registrationAddress`), the CIS switch (`rke2.cisProfile`) and the etcd snapshot schedule (`rke2.etcdSnapshots`). Operators run `make preflight`, `make bootstrap-k8s` and, to remove a cluster, `make rke2-uninstall CONFIRM=yes`.

RKE2 deploys Traefik as its default ingress controller from v1.36. The role sets `ingress-controller: none`, so RKE2 deploys no bundled ingress controller, and all north-south traffic goes through Gateway API ([ADR 0003](0003-gateway-api-with-envoy-gateway.md)).

The manifests in this repository do not depend on RKE2. The `lab` profile runs the same charts on kind through `make demo` for evaluation and CI ([ADR 0005](0005-lab-and-reference-profiles.md)).

### Consequences

- Good, because there is one provisioning path to test, document and upgrade.
- Good, because nodes carry neither a Docker engine nor a separate etcd: RKE2 embeds containerd and etcd and runs the control plane as static pods.
- Good, because HA, the CIS profile and etcd snapshots are configuration values in the cluster file, not extra roles.
- Good, because RKE2 upgrades can run through system-upgrade-controller Plans (optional `system-upgrade-controller` toolchain, off by default).
- Bad, because operators need RKE2-specific knowledge: its configuration file, its bundled components, its supervisor port and its own snapshot and restore procedure.
- Bad, because the platform can adopt a Kubernetes minor only after RKE2 ships it.
- Bad, because RKE2 changes bundled defaults between minors (Traefik became the default in v1.36, and ingress-nginx is removed for new clusters in v1.37), so every minor upgrade needs its release notes read.
- Bad, because sites standardised on another distribution or a managed service can reuse the GitOps layer but not the provisioning layer.
- Bad, because CI does not install RKE2 on virtual machines: the kind end-to-end job proves the manifests, not the RKE2 role. The RKE2 install is tested by [`tests/integration/rke2/run.sh`](../../tests/integration/rke2/README.md), a local harness that installs one server on a Lima VM and is run by hand; no workflow runs it. Agents and multi-server HA are not covered by it.
- Neutral, because the CIS profile stays optional (`rke2.cisProfile`), since it needs host preparation that not every lab host has.
- Neutral, because host creation stays outside this decision. An optional OpenTofu example under `infra/` covers one cloud target; the Ansible layer works on any reachable host in the supported OS matrix.

### Confirmation

- The `ansible` job in `.github/workflows/validate.yml` runs ansible-lint with the production profile, a syntax check of the playbooks and the Molecule scenarios of the roles (`make ansible-lint`, `make molecule`).
- The `config` job (`make validate-config`) validates every `clusters/*/cluster.yaml` against `clusters/schema.json` and reports placeholder values as warnings. `make validate-config STRICT=1 CLUSTER=<name>` rejects them, and `make preflight` rejects an `rke2.version` of `CHANGE_ME`.
- Review: `ansible/roles/` contains no other Kubernetes provisioner. A pull request that adds one needs a new ADR that supersedes this one.

## Pros and cons of the options

### RKE2

- Good, because containerd and etcd are embedded and the control plane runs as static pods.
- Good, because `profile: cis` applies the CIS settings, backed by a published hardening guide.
- Good, because HA uses a fixed registration address, and air-gap installation from release tarballs is documented.
- Good, because scheduled etcd snapshots, with optional upload to S3, are built in.
- Bad, because bundled components (CNI, CoreDNS, metrics-server, ingress) follow RKE2 releases, and their defaults can change between minors.
- Bad, because upgrade and restore procedures are specific to RKE2.

### RKE1

- Good, because it was widely deployed and well documented.
- Bad, because it reached end of life on 31 July 2025 and receives no further releases or security fixes.
- Bad, because it runs the Kubernetes components in Docker containers, so every node needs a Docker engine.

### k3s

- Good, because it uses the same installer and configuration style as RKE2, ships as one binary and has a small footprint.
- Good, because it supports embedded etcd for HA and air-gap installation.
- Bad, because its defaults target edge and small clusters (SQLite for a single server, bundled Traefik, ServiceLB and local-path), which the platform would mostly switch off.
- Bad, because CIS hardening needs more manual flags and files than the single `profile` setting of RKE2.

### kubeadm

- Good, because it is the upstream reference tool, with no distribution layer, and every Kubernetes minor is available on release day.
- Bad, because the operator must choose, install and upgrade the container runtime, the CNI and the API server load balancer separately, which means more Ansible code to maintain.
- Bad, because etcd snapshot scheduling, CIS hardening and air-gap packaging are left to the operator.

### Talos Linux

- Good, because it is a minimal, immutable, API-managed operating system without SSH, which gives a strong security baseline.
- Bad, because it replaces the host operating system: the supported OS matrix and the Ansible layer would be dropped, not reused.
- Bad, because operators need its own CLI and a different model for debugging, upgrades and recovery.

## More information

Upstream sources, checked on 2026-11-16:

- RKE1 end of life: <https://www.suse.com/c/rke-end-of-life-by-july-2025-replatform-to-rke2-or-k3s>
- RKE2 networking services and the bundled ingress controller: <https://docs.rke2.io/networking/networking_services>
- RKE2 high availability: <https://docs.rke2.io/install/ha>
- RKE2 air-gap installation: <https://docs.rke2.io/install/airgap>
- RKE2 etcd backup and restore: <https://docs.rke2.io/datastore/backup_restore>
- RKE2 CIS hardening guide: <https://docs.rke2.io/security/hardening_guide>
- k3s: <https://docs.k3s.io/>, kubeadm: <https://kubernetes.io/docs/reference/setup-tools/kubeadm/>, Talos Linux: <https://www.talos.dev/>, kind: <https://kind.sigs.k8s.io/>

Related pages and decisions:

- [Production setup](../getting-started/production-setup.md) and [RKE2 upgrades](../operations/upgrade-rke2.md)
- [Cluster configuration reference](../reference/configuration.md) and [support matrix](../reference/support-matrix.md)
- [ADR 0003: Gateway API with Envoy Gateway](0003-gateway-api-with-envoy-gateway.md)
- [ADR 0005: lab and reference profiles](0005-lab-and-reference-profiles.md)
