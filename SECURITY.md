# Security policy

## Reporting a vulnerability

Report vulnerabilities privately through GitHub private vulnerability reporting: open the repository's **Security** tab and choose **Report a vulnerability**, or go directly to <https://github.com/SritharanK/sk-k8s-devops-bootstrap/security/advisories/new>.

Do not open a public issue, pull request or discussion for a suspected vulnerability.

Include in the report:

- the affected file, chart, policy, workflow or role, and the commit or release;
- the profile (`lab` or `reference`) and the steps to reproduce;
- the impact you expect, and any proof of concept;
- whether the issue is in this repository or in an upstream component.

## What to expect

This is a reference project maintained on a best-effort basis, without a commercial support agreement.

| Step | Target |
| --- | --- |
| Acknowledgement of the report | within 5 working days |
| First assessment (accepted or declined, severity) | within 10 working days |
| Fix or mitigation for accepted High and Critical issues | as soon as practical, normally within 30 days |
| Public disclosure | coordinated with the reporter, at the latest 90 days after the report |

Accepted issues are fixed on `main`, released as a patch version and published as a GitHub security advisory with credit to the reporter, unless the reporter asks to stay anonymous.

## Supported versions

| Version | Supported |
| --- | --- |
| The `main` branch | Yes, until the first release; after that, the latest release and `main` |

## Scope

In scope:

- configuration and code in this repository: Ansible roles and playbooks, wrapper chart values, the `helm-common` chart, Kyverno policies, NetworkPolicies, AppProjects, scripts, GitHub Actions workflows and the `hello-api` sample service;
- insecure defaults in the `reference` profile.

Out of scope:

- vulnerabilities in upstream components such as Kubernetes, RKE2, Argo CD, cert-manager, Kyverno or Envoy Gateway. Report those to the upstream project. If a released version pinned here is affected, a regular issue asking for an update is welcome once the upstream advisory is public;
- the `lab` profile's documented trade-offs (self-signed certificates, the Argo CD initial admin secret, image verification off), listed in [known limitations](docs/security/known-limitations.md);
- deployments that changed the defaults.

## Security documentation

- [Security controls](docs/security/controls.md): what is enforced, where, and how it is tested.
- [Threat model](docs/security/threat-model.md).
- [Supply chain](docs/security/supply-chain.md): signing, SBOM, provenance and how to verify an image.
- [Secrets handling](docs/security/secrets-handling.md) and [secret rotation](docs/operations/secret-rotation.md).
- [Known limitations](docs/security/known-limitations.md).
