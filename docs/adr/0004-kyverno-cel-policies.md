---
status: accepted
date: 2026-11-16
decision-makers: platform maintainers
---

# Kyverno CEL policies for admission control

This record explains which admission policy engine the platform uses, in which policy format, and how it layers with Pod Security Admission. It is for operators, policy authors and app owners whose workloads must pass admission.

## Context and problem statement

Every pod in `dev`, `stage` and `prod` must meet the workload contract: `runAsNonRoot: true` at pod and container level, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `seccompProfile.type: RuntimeDefault`, `readOnlyRootFilesystem: true`, CPU and memory requests and limits, readiness and liveness probes, an explicit tag that is not `latest` or a digest, and a registry from an allowlist. In `stage` and `prod` of the `reference` profile, images must also carry a valid signature ([ADR 0008](0008-keyless-image-signing.md)). Kyverno 1.17 deprecated the `ClusterPolicy` format, with removal planned for a later release.

Which engine and which policy format should enforce this contract, and how do they relate to the built-in Pod Security Admission?

## Decision drivers

- Coverage of the whole workload contract, including rules that the Pod Security Standards do not express.
- Image signature verification at admission.
- A supported, non-deprecated policy API.
- Policies tested offline in CI with positive and negative fixtures.
- Audit mode in `dev` and enforcement in `stage` and `prod` from the same policy source.
- Narrow, reviewable exceptions that app owners cannot grant themselves.

## Considered options

- Kyverno `ClusterPolicy`
- Kyverno CEL policies (`ValidatingPolicy` and `ImageValidatingPolicy`)
- Kubernetes `ValidatingAdmissionPolicy` only
- OPA Gatekeeper
- Pod Security Admission only

## Decision outcome

Chosen option: "Kyverno CEL policies", because it is the only option that covers the full contract including image signatures with a policy API that is current (v1 since Kyverno 1.17), and it can be tested offline with `kyverno test`.

Layering:

1. Pod Security Admission is the first layer. The `misc` chart labels the `dev`, `stage` and `prod` namespaces with the restricted profile and a pinned version. It needs no extra component.
2. Kyverno is the second layer. The `kyverno` toolchain (wave 1) installs the engine. The chart `helmcharts/system-charts/kyverno-policies` (wave 3) renders `ValidatingPolicy` objects for the whole contract, including the parts that PSA cannot express (read-only root filesystem, resources, probes, tag and registry rules), and an `ImageValidatingPolicy` for signatures.
3. Modes per environment: `dev` runs Audit, `stage` and `prod` Enforce. Image verification is enabled only for `stage` and `prod` in the `reference` profile and disabled in `lab`.
4. Exceptions are `PolicyException` objects in the `kyverno` namespace, owned by the platform. Example: ACME HTTP-01 solver pods, matched by the label `acme.cert-manager.io/http01-solver: "true"`. The app AppProjects allow only their own namespace, so app owners cannot create exceptions.

### Consequences

- Good, because the whole contract is enforced in `stage` and `prod`, and reported in `dev` without blocking work.
- Good, because CEL is the same expression language as the Kubernetes `ValidatingAdmissionPolicy`, so authors learn one language.
- Good, because Kyverno writes PolicyReports from background scans, which show violations of objects admitted before a policy changed.
- Good, because the fixtures that prove each rule live next to the policies and run on every pull request.
- Bad, because Kyverno is an admission webhook. If it is unavailable, pod creation in enforced namespaces fails or bypasses the checks, depending on the webhook failure policy. The admission controller needs several replicas and a PodDisruptionBudget in the `reference` profile.
- Bad, because the CEL policy types are newer than `ClusterPolicy`, so fewer community examples exist.
- Bad, because Kyverno-specific CEL functions (for example for images) do not carry over to a native `ValidatingAdmissionPolicy`.
- Bad, because two layers can report the same violation; for restricted-profile violations at pod level the PSA message may appear first.
- Neutral, because the migration from `ClusterPolicy` is a one-time cost that the deprecation imposes on every Kyverno user.

### Confirmation

- `make policy-test` (script `hack/policy-test.sh`) runs `kyverno test` on the fixtures in `helmcharts/system-charts/kyverno-policies/tests/`.
- The `policy-test` job in `.github/workflows/validate.yml` runs the same tests and applies the rendered policies with `kyverno apply` to every rendered app and environment. The owned app must show zero violations.
- The `e2e-kind` job asserts that privileged, root and `:latest` pods are denied.
- Review: a new `PolicyException` names the exact workload it covers and lives in the `kyverno` namespace.

## Pros and cons of the options

### Kyverno `ClusterPolicy`

- Good, because it is mature, widely documented and supports validate, mutate, generate and image verification rules.
- Bad, because Kyverno 1.17 deprecated it, and the release announcement gives an estimated schedule for its removal. Choosing it now means a second migration later.

### Kyverno CEL policies (`ValidatingPolicy` and `ImageValidatingPolicy`)

- Good, because the CEL policy types reached v1 in Kyverno 1.17.
- Good, because they cover validation, image signature verification, background reports and exceptions in one engine.
- Good, because `kyverno test` and `kyverno apply` run them offline in CI.
- Bad, because the engine runs as a webhook with its own availability and upgrade concerns.

### Kubernetes `ValidatingAdmissionPolicy` only

- Good, because it runs inside the API server, with no webhook and no extra component.
- Good, because it uses CEL, like the chosen option.
- Bad, because it cannot verify image signatures: it has no access to registries.
- Bad, because it evaluates only at admission and produces no reports for objects that already exist.

### OPA Gatekeeper

- Good, because it is mature, offers audit of existing objects and has a large policy library.
- Bad, because most of that library is written in Rego, a separate language.
- Bad, because image verification needs an external data provider, which is one more component.

### Pod Security Admission only

- Good, because it is built in and needs no component or webhook.
- Bad, because it covers only the Pod Security Standards. It cannot require a read-only root filesystem, resources, probes, tag or registry rules, or signatures.

## More information

Upstream sources, checked on 2026-11-16:

- Kyverno 1.17 announcement (deprecation of `ClusterPolicy`, CEL types at v1): <https://www.cncf.io/blog/2026/02/18/announcing-kyverno-1-17/>
- Migration to CEL policies: <https://kyverno.io/docs/guides/migration-to-cel/>
- `ValidatingPolicy`: <https://kyverno.io/docs/policy-types/validating-policy/>
- `ImageValidatingPolicy`: <https://kyverno.io/docs/policy-types/image-validating-policy/>
- Policy exceptions: <https://kyverno.io/docs/exceptions/>
- Kyverno CLI: <https://kyverno.io/docs/kyverno-cli/>
- `ValidatingAdmissionPolicy`: <https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/>
- Pod Security Admission: <https://kubernetes.io/docs/concepts/security/pod-security-admission/>
- OPA Gatekeeper: <https://open-policy-agent.github.io/gatekeeper/website/docs/>

Related pages and decisions:

- [Security controls](../security/controls.md), [threat model](../security/threat-model.md), [known limitations](../security/known-limitations.md)
- [helm-common values and the workload contract](../reference/helm-common-values.md)
- [ADR 0008: keyless image signing](0008-keyless-image-signing.md)
- [ADR 0010: Go sample service](0010-go-sample-service.md)
