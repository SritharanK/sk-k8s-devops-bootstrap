# Known limitations

This page lists the limitations and accepted risks of the platform as it is built today, with the impact of each and the mitigation or plan. It is for reviewers and for operators who decide whether the platform fits their own risk appetite. The controls themselves are in [security controls](controls.md); the threats they address are in the [threat model](threat-model.md).

Each entry states the limitation, its impact, and the mitigation or plan. Advice is kept apart in a separate recommendation line.

## Profiles and topology

### The lab profile is a demonstration environment

The `lab` profile uses the cert-manager `selfsigned` issuer and the Argo CD initial admin secret. Argo CD pulls from an in-cluster Gitea seeded from the local `HEAD`, so a local commit reaches the lab cluster without review. kind does not encrypt Secrets at rest.

- Impact: browsers and clients do not trust the lab certificates. The admin password in `argocd-initial-admin-secret` grants full Argo CD rights to anyone who can read that Secret. The lab cluster is fit for a workstation demonstration and for CI, not for real data.
- Mitigation: the `reference` profile uses `letsencrypt-staging` or `letsencrypt`, OIDC SSO with the local admin disabled, and GitHub over HTTPS.
- Recommendation: never expose a lab cluster beyond the workstation that runs it.

### Image signatures are not verified in lab or in dev

Kyverno verifies image signatures only in `stage` and `prod` of the `reference` profile. The `lab` profile disables verification because the demo loads a locally built, unsigned image into kind. `dev` does not verify in either profile, so test builds can run there.

- Impact: an unsigned or foreign image from an allowlisted registry can run in `dev`, and in every app namespace of a lab cluster.
- Mitigation: the registry allowlist and the tag rule still apply (Audit in `dev`). Promotion copies only digests that ran in the previous environment, and `stage` and `prod` reject unsigned images in `reference`. See [supply chain](supply-chain.md#admission).

### One cluster hosts dev, stage and prod

Both profiles run the three environments as namespaces of one cluster.

- Impact: a cluster-level compromise (Argo CD, the API server, etcd, a node, or a flaw in the CNI or in admission) spans all environments. Node-level resource pressure from `dev` can affect `prod`. A platform component upgrade reaches `prod` at the same time as `dev`.
- Mitigation: AppProjects, ResourceQuota and LimitRange, default-deny NetworkPolicies, Pod Security Admission and Kyverno bound what a workload can do inside its namespace.
- Alternative: a two-cluster topology (nonprod with `dev` and `stage`, and prod, with a hub Argo CD) is implemented in the bootstrap chart as hub mode and not tested in CI; see [`bootstrap/README.md`](../../bootstrap/README.md). It separates control planes, nodes and platform components, but the hub Argo CD holds credentials for both clusters.

## Identity and access

### Git write access to platform paths equals cluster-admin

The `platform` project installs CRDs, webhooks, ClusterRoles and ClusterRoleBindings, so the Argo CD application controller holds cluster-wide write permissions. Whoever can merge to the paths it deploys from controls the cluster. The branch ruleset that requires pull requests and `ci-gate` is a GitHub repository setting, not a file in the repository.

- Impact: a compromised maintainer account, or a fork of the repository without a ruleset, removes the main control on cluster changes.
- Mitigation: pull-request review, `ci-gate`, CODEOWNERS for `envs/prod/` and the prod sync window. See [AppProjects limit Applications, not the Argo CD controller](controls.md#appprojects-limit-applications-not-the-argo-cd-controller).
- Recommendation: configure the ruleset (required pull request, required `ci-gate`, no force-push) before connecting a cluster to the repository.

### The admin kubeconfig is a long-lived superuser credential

Ansible fetches the RKE2 admin kubeconfig to `ansible/data/`. Its client certificate belongs to the `system:masters` group, which bypasses RBAC, and it cannot be revoked on its own.

- Impact: anyone who obtains the file is cluster-admin until the cluster's client certificates are rotated.
- Mitigation: the file is gitignored and written with mode 0600.
- Recommendation: enable the API server OIDC authenticator (`rke2_apiserver_oidc` in the `rke2` role, off by default) for daily access, bind the `oidc:` prefixed groups through RBAC, and keep the admin kubeconfig for break-glass use. Rotation is described in [secret rotation](../operations/secret-rotation.md).

### SSO depends on the operator's identity provider

The `reference` profile configures Argo CD SSO, but it works only once the operator has registered a client in an identity provider that emits a groups claim. Roles are mapped from `platform.groups`, and `policy.default` is empty, so a user whose groups do not match gets no rights. The Kubernetes API authenticator (`rke2_apiserver_oidc`) is off by default, so the Kubernetes RBAC group bindings have no effect until it is configured.

- Impact: until SSO works, a `reference` cluster has no Argo CD sign-in unless the local admin is re-enabled. Multi-factor authentication, joiner and leaver handling and session policy are controls of the identity provider, not of this platform. An identity-provider outage blocks sign-in to Argo CD; Argo CD keeps syncing from Git.
- Mitigation: [Argo CD SSO](argocd-sso.md) describes the setup and how to verify it before the local admin is disabled.

### The kyverno-policies chart default accepts any repository owner

Through Argo CD, the `kyverno-policies` toolchain pins the image signing identity to the owner and repository of `git.repoURL`, or fails the render when verification is on and no identity can be derived or is set. The chart's own default `subjectRegExp` still contains `[^/]+` for the owner, so a fork with the same repository name would match it.

- Impact: only when the chart is installed without the toolchain (plain `helm install` with its default values) and verification is enabled.
- Mitigation: the GitOps path always passes the pinned identity; the registry allowlist and the registry's own write permissions keep images from other owners out.
- Recommendation: outside the GitOps path, set `imageVerification.subjectRegExp` to your owner and repository, see [supply chain](supply-chain.md#push-sign-and-attest).

### Argo CD traffic behind the Gateway is not encrypted inside the cluster

TLS ends at the Gateway. Argo CD runs with `server.insecure: true`, so the hop from Envoy Gateway to `argocd-server` is plain HTTP on the pod network.

- Impact: an attacker with access to that network path, for example root on a node, can read Argo CD session tokens in transit.
- Mitigation: default-deny NetworkPolicies in `argocd` limit who can reach `argocd-server`. Encryption of pod traffic by the CNI is possible with Calico or Cilium and is not configured by this repository.

## Secrets

### Sealed Secrets has no central rotation or audit

In the `lab` profile, secret values live as SealedSecrets in Git.

- Impact: there is no record of who sealed or read a value, no expiry, and no central place to rotate it. Rotating a value means sealing it again and committing it. Losing the controller key without a backup makes every SealedSecret unrecoverable.
- Mitigation: Sealed Secrets is limited to the `lab` profile. The `reference` profile uses ESO with OpenBao, which stores values centrally, audits access and refreshes Secrets in the cluster. Key escrow is in [backup and restore](../operations/backup-and-restore.md), rotation in [secret rotation](../operations/secret-rotation.md).

### One ClusterSecretStore serves every environment

In the `reference` profile the OpenBao chart renders one `ClusterSecretStore`, `openbao`, without namespace conditions. It logs in to OpenBao as the role `external-secrets`, whose policy in the OpenBao chart runbook reads every path under `secret/`.

- Impact: an ExternalSecret in any namespace can read any value under `secret/`, so a `dev` workload or a `dev` values change can read a `prod` secret.
- Mitigation: none by default. Review of ExternalSecrets in pull requests is the only control.
- Recommendation: one store per environment, each restricted to its namespace with `spec.conditions`, with its own OpenBao role and a policy limited to that environment's path. See [secrets handling](secrets-handling.md#recommended-hardening-one-store-per-environment).

## Supply chain

### Platform component images are not signature-verified

Argo CD, Kyverno, cert-manager, Envoy Gateway and the other platform components run the images their upstream charts reference. Image verification covers app images in `stage` and `prod` only.

- Impact: a compromised upstream image would run in the platform namespaces.
- Mitigation: wrapper charts pin exact upstream versions, and Renovate proposes every change as a reviewed pull request. The full list of supply-chain gaps is in [supply chain](supply-chain.md#what-is-not-covered).

## Detection and audit

### API audit logs stay on the nodes and the RKE2 CIS profile is opt-in

The `rke2` role installs an API server audit policy by default (`rke2_audit_policy_enabled: true`). Each server writes its log to `/var/lib/rancher/rke2/server/logs/audit.log`, rotated by size and age; nothing ships it off the nodes. kind clusters have no audit log. The RKE2 CIS profile is switched on per cluster with `rke2.cisProfile`; the shipped `reference` cluster file sets it to `true`, the role default is `false`.

- Impact: an attacker with root on a server node can change or delete the audit records, and a lost node takes its records with it. Without the CIS profile, the host hardening it requires is absent and there is no cluster-wide `restricted` Pod Security default; namespaces without a Pod Security label are not restricted. The labels on `dev`, `stage`, `prod` and `argocd` still enforce.
- Mitigation: the audit log records direct API access, including break-glass use of the admin kubeconfig, as long as the server keeps it. The CIS profile is a choice the operator makes per cluster.
- Recommendation: for any cluster with real data, keep `rke2.cisProfile: true` and ship the audit log off the nodes to storage the cluster administrators cannot change.

### Runtime detection and continuous rescanning are off by default

Falco (runtime detection) and Trivy Operator (continuous image rescanning) are available as optional components and are off by default (`toolchains.falco.enabled`, `toolchains.trivy-operator.enabled`).

- Impact: a compromise at runtime raises no alert. A vulnerability published after an image was built is found by the daily `rescan` job of `build-image.yml` for the digests pinned in `envs/`; in the `reference` profile new pods of a digest with a new CRITICAL finding are then denied in `stage` and `prod`, but running pods keep running and nothing alerts on images outside `envs/`.
- Mitigation: admission controls, default-deny NetworkPolicies and the read-only root filesystem limit what a compromised container can do. Rebuilds through Renovate pull requests rescan images. If the rescan stops for longer than `maxScanAge`, new and rescheduled pods in `stage` and `prod` are denied; dispatch `build-image.yml` with `rescan` to recover.

## Optional components

### Kargo writes to the repository with a standing credential

With the `kargo` toolchain on, as in the shipped `reference` cluster file, Kargo is the promotion engine of the repository ([ADR 0012](../adr/0012-kargo-promotion.md)).

- Impact: Kargo commits the `dev` and `stage` environment files directly, so those promotions skip pull request review and `ci-gate`. Its Git credential is a standing secret with write access to the repository. The engine applies to the whole repository: a cluster file that enables Kargo also stops the workflows for every other cluster of the repository.
- Mitigation: [promote with Kargo](../how-to/promote-with-kargo.md#prerequisites) prescribes a token limited to this repository with Contents and Pull requests permissions; it lives in OpenBao (`reference`) or a SealedSecret (`lab`). Kargo changes only `image.tag` and `image.digest` under `envs/`; each stage after the first accepts only Freight verified in the stage before, and `prod` stays a pull request under CODEOWNERS. The repository variable `PROMOTION_ENGINE=workflows` keeps every promotion a pull request.

### Preview environments deploy pull request content

Preview environments are off by default ([preview environments](../how-to/preview-environments.md)).

- Impact: a pull request with the preview label, including one from a fork, deploys the charts and values of its head commit into the namespace `pr-<number>`. With `image.tagFromHeadSha`, it also runs the image built from that commit.
- Mitigation: only users who can label pull requests start a preview. The namespace runs with Pod Security `restricted`, a ResourceQuota, a LimitRange and default-deny NetworkPolicies, inside the `apps-preview` and `preview-namespaces` AppProjects; the generator token is read-only, and the namespace is removed when the pull request closes.

### The Jenkins adapter has a larger attack surface

Jenkins is an optional on-premises CI adapter, installed only with `make install-jenkins`. A Jenkins controller is a long-running service with plugins that holds registry and Git credentials and runs pipeline code.

- Impact: more components to patch and more standing credentials than GitHub Actions, whose jobs run on ephemeral runners with short-lived tokens. Jenkins signs images with a long-lived cosign key pair, which is one more standing secret. Those images do not carry the GitHub Actions signing identity and are rejected in `stage` and `prod` of the `reference` profile unless the policy is extended with the Jenkins public key.
- Mitigation: the adapter runs the controller with 0 executors, runs only sandboxed declarative pipelines from SCM, builds on Kubernetes agents with rootless BuildKit, reads credentials from JCasC file secrets and sits behind TLS.
- Recommendation: use GitHub Actions unless an on-premises requirement rules it out.
