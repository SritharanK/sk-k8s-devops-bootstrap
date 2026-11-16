---
status: accepted
date: 2026-11-16
decision-makers: platform maintainers
---

# Keyless image signing with admission verification

This record explains how images are signed and attested in CI and verified at admission. It is for operators who run `stage` and `prod`, and for reviewers of the supply chain.

## Context and problem statement

Images move from CI to the cluster by digest ([ADR 0011](0011-promotion-by-pull-request-and-digest.md)). A digest proves that the bytes did not change, but not who built them or how. The cluster should admit into `stage` and `prod` only images built by this repository's own build workflow, and anyone should be able to check how an image was built and what it contains.

How should images be signed and attested, and how should the cluster verify them?

## Decision drivers

- No long-lived signing key to store, rotate or leak.
- A signer identity tied to a specific workflow, repository and branch.
- Verification at admission, in the same policy engine as the workload contract ([ADR 0004](0004-kyverno-cel-policies.md)).
- SBOM and build provenance that third parties can verify.
- A local demo that still works with a locally built image.

## Considered options

- No signing
- cosign with a long-lived key pair
- Keyless cosign through GitHub OIDC, plus GitHub artifact attestations
- Notation (Notary Project)

## Decision outcome

Chosen option: "Keyless cosign through GitHub OIDC, plus GitHub artifact attestations", because it needs no key management, binds each signature to the workflow that built the image, and Kyverno verifies it natively.

How it works:

1. On `main`, `build-image.yml` tests the service, builds it with `docker buildx` (SBOM and maximum provenance), pushes it to GHCR, scans the pushed digest with Trivy (failing on fixable CRITICAL and HIGH findings, which leaves the image unsigned), then signs the digest with cosign keyless, creates GitHub artifact attestations, and outputs the digest.
2. The signing certificate comes from the Sigstore certificate authority (Fulcio), based on the GitHub OIDC token of the run, and the signature is recorded in the public transparency log (Rekor).
3. A Kyverno `ImageValidatingPolicy` admits images in `stage` and `prod` of the `reference` profile only when they carry a signature with this identity. The policy values are `imageVerification.enabled`, `imageVerification.issuer`, `imageVerification.subjectRegExp` and `imageVerification.registries`:

```text
issuer:         https://token.actions.githubusercontent.com
subject regexp: ^https://github\.com/<owner>/<repo>/\.github/workflows/build-image\.yml@refs/heads/main$
```

Verification is disabled in the `lab` profile, because the kind demo loads a locally built, unsigned image.

The admission policy checks the signature and its identity, and the vulnerability attestation described below. The SBOM and provenance attestations serve audit. Anyone can verify both, the signature with cosign and the attestations with the GitHub CLI:

```bash
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/YOUR_ORG/sk-k8s-devops-bootstrap/\.github/workflows/build-image\.yml@refs/heads/main$' \
  ghcr.io/your-org/hello-api@sha256:CHANGE_ME
gh attestation verify oci://ghcr.io/your-org/hello-api@sha256:CHANGE_ME --repo YOUR_ORG/sk-k8s-devops-bootstrap
```

`<owner>/<repo>` is pinned, not a wildcard: a fork's signature combined with a stolen registry credential must not be enough to get an image admitted. The `kyverno-policies` toolchain (`argocd-bootstrap/templates/toolchains/kyverno-policies.yaml`) derives the owner and repository from `git.repoURL` in the cluster file. It accepts `https://github.com/<owner>/<repo>[.git]`, `git@github.com:<owner>/<repo>[.git]` and `ssh://git@github.com/<owner>/<repo>[.git]`. An explicit `toolchains.kyverno-policies.values.imageVerification.subjectRegExp` in the cluster file wins. When verification is on (the `reference` profile, or `imageVerification.enabled: true` in the cluster file) and neither gives an identity, for example with a mirror on another Git host, the render fails with a message that names the missing value, so the policy never falls back to an identity that accepts any owner. `argocd-bootstrap/tests/signing_test.yaml` covers each case and runs in `make helm`.

The same identity signs a vulnerability attestation, so admission can decide on a scan that is signed and recent, not only on the scan at build time:

1. After signing, `build-image.yml` attests the Trivy report of the digest with `cosign attest --type vuln` (predicate type `https://cosign.sigstore.dev/attestation/vuln/v1`: every finding, fixed or not, and the scan time). The daily `rescan` job of the same workflow, on `main`, scans every digest pinned in `envs/` again and attests the new report.
2. With `imageVerification.vulnerabilities.enabled`, on in the `reference` profile, the same `ImageValidatingPolicy` also requires that attestation from the same attestor, a newest scan no older than `maxScanAge` (default `168h`), and no finding with a severity in `severities` (default `CRITICAL`, unfixed findings included) except the accepted IDs in `ignoreVulnerabilityIDs`. When several attestations verify, the newest decides.

For setups that sign with a key pair or a KMS key, `imageVerification.publicKey` replaces the keyless identity in the same policy, for the signature and the attestation. This repository's workflow keeps signing keyless. The values, the operational consequences and the risk acceptance process are in [supply chain](../security/supply-chain.md#vulnerability-attestation-gate).

### Consequences

- Good, because there is no signing key to store, rotate or revoke.
- Good, because, with the owner pinned in `subjectRegExp`, a stolen registry credential is not enough to get an image into `stage` or `prod`; the image also needs a signature from the build workflow on `main`.
- Good, because SBOM and SLSA provenance are attached to every image and verifiable without access to the CI system.
- Good, because a vulnerability published after the build blocks new pods of a deployed digest in `stage` and `prod` within a day of the rescan, without a rebuild, and the denial names the finding.
- Bad, because signing depends on the public Sigstore services (Fulcio and Rekor). When they are unavailable, the build cannot sign and the image cannot be promoted to a verified environment.
- Bad, because the identity is tied to the workflow path and the branch. Renaming `build-image.yml`, building from a tag or from another branch, or moving the repository breaks verification until the policy values change.
- Bad, because every signature is recorded in a public transparency log, which reveals the repository and workflow names. That is acceptable for a public repository and a concern for private ones.
- Bad, because verification is disabled in `lab`, so the local demo and the kind end-to-end job do not exercise this control.
- Bad, because the workflow pushes the image before it signs it, so the registry can hold unsigned digests from failed runs. Admission rejects them in `stage` and `prod`, but not in `dev` or `lab`.
- Bad, because images built by the optional Jenkins adapter carry no signature with this identity ([ADR 0009](0009-github-actions-reference-ci-jenkins-optional.md)).
- Bad, because a new CRITICAL finding in a deployed digest, or a rescan that does not run for longer than `maxScanAge`, stops new pods of that image in `stage` and `prod`, including pods rescheduled after a node drain. Running pods are not affected.
- Bad, because the build gate (fixable CRITICAL and HIGH) and the admission gate (CRITICAL, fixed or not) differ, so an image with an unfixed CRITICAL finding runs in `dev` and is denied in `stage`.
- Bad, because an entry in `ignoreVulnerabilityIDs` accepts the finding for every image the policy checks, not for one image.
- Neutral, because air-gapped clusters need a mirrored Sigstore trust root for verification.
- Neutral, because `imageVerification.publicKey` lets a setup without the public Sigstore services verify key-based signatures and attestations, while `build-image.yml` only produces keyless ones.

### Confirmation

- A run of `build-image.yml` fails when signing or attestation fails.
- The `workflow-lint` job (actionlint, zizmor) checks every workflow, including its permissions.
- The `policy-test` job runs the Kyverno policy tests on every pull request.
- The `policy-test-attestations` job runs the vulnerability attestation gate on every pull request, against images signed and attested with an ephemeral key in a throwaway local registry.
- `build-image.yml` verifies the vulnerability attestation with `cosign verify-attestation` against the identity above before it tags a release, and the `rescan` job verifies every attestation it creates.
- Manual check after a change to the policy or the workflow: an unsigned image is denied in `stage` of a `reference` cluster, and the `cosign verify` command above succeeds for the latest build.
- Review: changes to the `imageVerification` values and changes to the name or trigger of `build-image.yml` are reviewed together.

## Pros and cons of the options

### No signing

- Good, because it needs nothing.
- Bad, because anyone who can push to the registry can get an image admitted.

### cosign with a long-lived key pair

- Good, because it works offline and air-gapped, with no dependency on public services.
- Bad, because the private key must be stored in CI, rotated and revoked by hand, and a leaked key lets anyone sign.
- Bad, because the signature says which key signed, not which workflow built the image.

### Keyless cosign through GitHub OIDC, plus GitHub artifact attestations

- Good, because certificates are short-lived and bound to the workflow identity.
- Good, because Kyverno and cosign verify the signature, and the GitHub CLI verifies the attestations.
- Bad, because it depends on Sigstore availability and on the exact workflow path and branch.

### Notation (Notary Project)

- Good, because it uses X.509 certificates, which suits organisations with an existing PKI, and Kyverno can verify it.
- Bad, because it needs a certificate authority, key storage and revocation, which this repository does not have.
- Bad, because GitHub artifact attestations would still be a separate mechanism.

## More information

Upstream sources, checked on 2026-11-16:

- cosign signing overview: <https://docs.sigstore.dev/cosign/signing/overview/>
- Sigstore: <https://docs.sigstore.dev/>
- GitHub OIDC: <https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/about-security-hardening-with-openid-connect>
- GitHub artifact attestations: <https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations/using-artifact-attestations-to-establish-provenance-for-builds>
- Kyverno `ImageValidatingPolicy`: <https://kyverno.io/docs/policy-types/image-validating-policy/>
- cosign vulnerability attestation specification: <https://github.com/sigstore/cosign/blob/main/specs/COSIGN_VULN_ATTESTATION_SPEC.md>
- Trivy vulnerability scan attestation: <https://trivy.dev/latest/docs/supply-chain/attestation/vuln/>
- Notary Project: <https://notaryproject.dev/>

Related pages and decisions:

- [Supply chain](../security/supply-chain.md), [security controls](../security/controls.md), [CI/CD architecture](../architecture/ci-cd.md)
- [ADR 0004: Kyverno CEL policies](0004-kyverno-cel-policies.md)
- [ADR 0009: GitHub Actions as reference CI](0009-github-actions-reference-ci-jenkins-optional.md)
- [ADR 0011: promotion by pull request and digest](0011-promotion-by-pull-request-and-digest.md)
