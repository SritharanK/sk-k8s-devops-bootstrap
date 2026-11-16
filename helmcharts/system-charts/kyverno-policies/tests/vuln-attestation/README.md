# Vulnerability attestation gate test

Offline check of the vulnerability scan gate in `templates/imagevalidatingpolicy.yaml` (`imageVerification.vulnerabilities`): the policy rendered from the chart admits or denies pods by the cosign vulnerability attestation of their images, evaluated by the Kyverno CLI against a throwaway local registry.

```bash
make policy-test-attestations
```

Requirements: Docker, cosign 3.1.4 or later, the kyverno CLI 1.20.0 or later, helm, jq and curl. Network access is needed only to pull the registry image (`registry:3.1.2`, pinned by digest). The run takes about ten seconds once that image is present, removes its container, keys and temporary files on exit, and exits non-zero when any case has an unexpected result or reason. The CI job `policy-test-attestations` in `.github/workflows/validate.yml` runs it on every pull request.

Last result (2026-11-16, kyverno CLI 1.20.0, cosign 3.1.4, Docker 29.8): 11 tests passed with the chart defaults and 3 with `ignoreUnfixed: true`, 0 failed, and every denial carried its expected message.

## What the run does

1. Starts `registry:3.1.2` on `127.0.0.1` with a port that Docker picks. A container of the same name left over by an interrupted run is removed first.
2. Pushes one single-layer image per case through the registry HTTP API, each with a different file content and therefore a different digest. `docker push` is not used, because with Docker Desktop the daemon runs in a VM and cannot reach a registry bound to the loopback interface of the host.
3. Generates two ephemeral cosign key pairs in a temporary directory and signs every image with the first. The signing config has no transparency log and no timestamp authority (`cosign signing-config create` without services), so nothing leaves the machine.
4. Attests the predicates in `predicates/` with `cosign attest --type vuln`, with `metadata.scanStartedOn` and `metadata.scanFinishedOn` set at run time. The predicates are small Trivy `cosign-vuln` reports with fictitious CVE IDs.
5. Renders the policy from the chart with `chart-values.yaml`, the public key of the first pair (`imageVerification.publicKey`), `insecureIgnoreTlog: true` and the local registry as `imageVerification.registries`. The vulnerability settings are the chart defaults: maximum scan age `168h`, severity `CRITICAL`, unfixed findings block. `CVE-2099-0002` is in `ignoreVulnerabilityIDs`.
6. Runs `kyverno test` with `test.yaml` and the pods in `pods.yaml`, which run.sh points at the pushed digests, then checks that each denial carries the message of its own validation.
7. Renders the policy again with `ignoreUnfixed: true` and runs `test-ignore-unfixed.yaml` on the same pods.

The test files are not named `kyverno-test.yaml`, so `hack/policy-test.sh` (`make policy-test`) does not pick them up without the registry.

| Pod | Image attestations | Expected |
| --- | --- | --- |
| `pass` | Fresh scan, HIGH and MEDIUM findings only | Admitted |
| `pass-with-unmatched-image` | As `pass`, plus a sidecar outside `imageVerification.registries` | Admitted |
| `accepted-risk` | Fresh scan, one CRITICAL that is in `ignoreVulnerabilityIDs` | Admitted |
| `renewed` | Scan from 30 days ago, then a fresh clean scan | Admitted |
| `critical` | Fresh scan, one fixed and one unfixed CRITICAL | Denied, both IDs named; with `ignoreUnfixed: true` denied for the fixed one only |
| `unfixed` | Fresh scan, one unfixed CRITICAL | Denied; admitted with `ignoreUnfixed: true` |
| `critical-init` | `critical` as init container, `pass` as app container | Denied |
| `stale` | Clean scan from 30 days ago | Denied, scan too old |
| `missing` | Signed, no attestation | Denied, attestation missing |
| `foreign-attestation` | Signed with the test key, attested with another key | Denied, attestation missing |
| `regressed` | Fresh scan with CRITICAL findings, then an older clean scan | Denied, the newest scan decides |

## What it proves

- The rendered policy compiles and runs in the Kyverno 1.20 CEL engine, including the predicate type URI, the optional field access on the Trivy report, `time.now()`, and the message expressions.
- An image needs a vulnerability attestation that verifies with the same attestor as its signature. An attestation signed by another key does not count.
- A finding with a listed severity blocks admission, fixed or not, unless its ID is in `ignoreVulnerabilityIDs`; with `ignoreUnfixed: true`, only findings with a fixed version block. Lower severities do not block. Init containers are checked; images outside `imageVerification.registries` are not.
- A scan older than `maxScanAge` blocks admission. When an image has several attestations, the one with the newest scan decides, whatever the upload order: a rescan renews an old scan, and a rescan with a new CRITICAL finding blocks an image whose older scan was clean.
- The key-based attestor (`imageVerification.publicKey`) verifies signatures and attestations without a transparency log when `insecureIgnoreTlog` is set.

## What it does not prove

- The keyless identity. The test uses a key-based attestor offline, without Fulcio, Rekor or the Sigstore trust root. That the keyless attestor accepts only the build workflow identity is covered by `../image-verification/trusted-identity` and `../image-verification/repository-identity`, which use public images and need network access. The keyless attestor is the same object for signature and attestation, so the attestation check uses that identity as well.
- Which attestation is the newest with keyless signing. Kyverno orders attestations by the timestamp in the signature bundle when there is one, and by the statement time (`metadata.scanFinishedOn`) otherwise. This run has no bundle timestamp, so it exercises the second path only.
- The admission webhook. The CLI evaluates the policy as the admission controller does, but webhook timeouts, the digest mutation (`mutateDigest`) and `failurePolicy` are not exercised; the pods reference digests directly.
- `build-image.yml` itself: that Trivy writes this predicate shape and that the rescan job attests with the build identity is checked by the `cosign verify-attestation` steps of that workflow on `main`. The fixtures follow the shape of a Trivy 0.76.2 `cosign-vuln` report.
- Severity lists other than `[CRITICAL]` and the `Status` field as the only fix indicator: the fixtures with a fix carry both `FixedVersion` and `Status: fixed`.
