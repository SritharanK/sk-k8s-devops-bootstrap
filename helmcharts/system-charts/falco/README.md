# falco

Runtime threat detection on every node: Falco watches system calls through the modern eBPF probe and raises an alert when a container or host process matches a rule, for example a shell in a container, a write below `/etc` or an unexpected outbound connection.

| Item | Value |
| --- | --- |
| Upstream chart | falco 9.2.2 from `oci://ghcr.io/falcosecurity/charts` |
| Upstream app version | 0.45.2 (image `docker.io/falcosecurity/falco:0.45.2`) |
| Upstream source | <https://github.com/falcosecurity/falco> |
| Rules | falco-rules 5.2.0, shipped in the image (<https://github.com/falcosecurity/rules>) |
| Namespace | falco (Pod Security: privileged, the probe loads eBPF programs into the kernel and reads `/proc`, `/etc` and the container runtime sockets of the host) |
| Enabled by default | No. Switch on with `toolchains.falco.enabled: true` in `clusters/<cluster>/cluster.yaml`. |

## Design

| Setting | Value | Reason |
| --- | --- | --- |
| Driver | `modern_ebpf` | The CO-RE probe is compiled into the Falco binary: no kernel module, no driver download, no driver loader init container |
| Container security context | `privileged: true` (upstream default for `modern_ebpf`) | Works on every node OS regardless of AppArmor or SELinux policy |
| Tolerations | `operator: Exists` | One pod on every node, control-plane nodes included |
| Rules and plugins | From the image, falcoctl disabled | Deterministic, see below |
| Container metadata | container plugin 0.7.6 (bundled), containerd and CRI sockets only | Adds `container.*` and `k8s.pod.*`, `k8s.ns.name` fields to alerts |
| k8smeta plugin | off | Needs the separate k8s-metacollector Deployment; the CRI already gives pod, namespace and labels |
| Output | JSON on stdout, syslog off | Collected by the logging toolchain |
| falcosidekick | off | No alert forwarding beyond the logs |
| Metrics | Prometheus endpoint on port 8765, ServiceMonitor `release: monitoring` | Event drops, rule counters, resource use |

### Rules: why falcoctl is off

The upstream chart runs falcoctl as an init container and a sidecar. It installs `falco-rules:5` and the container plugin from OCI registries at every pod start and follows the rules tag weekly. `falco-rules:5` is a floating major tag, so two pods started a week apart can run different rules, and nothing in Git records which.

Falco 0.45.2 ships its own copies:

| File in the image | Content | How it was checked |
| --- | --- | --- |
| `/etc/falco/falco_rules.yaml` | falco-rules 5.2.0 | Falco 0.45.2 build pins `falco-rules-5.2.0` (`cmake/modules/rules.cmake`); the file in the image layer has the same sha256 as `falco_rules.yaml` in `https://download.falco.org/rules/falco-rules-5.2.0.tar.gz` |
| `/usr/share/falco/plugins/libcontainer.so` | container plugin 0.7.6 | Falco 0.45.2 build pins `CONTAINER_VERSION 0.7.6`, the same version the chart would install |

With falcoctl disabled, the rules and the plugin change only when the Falco image changes, which is a reviewed change to `Chart.yaml`. On 2026-11-16 5.2.0 was also the newest `falco-rules` 5.x tag, so this choice loses no rules today. It also removes the falcoctl image and the egress to the registries.

Platform rules and exceptions go into `falco.customRules` in `values.yaml`. The chart mounts them as a ConfigMap into `/etc/falco/rules.d`, which is loaded after the default rules.

## Profiles

| Setting | lab | reference |
| --- | --- | --- |
| Pods | one per node (DaemonSet) | one per node (DaemonSet) |
| Requests / memory limit | 100m, 256Mi / 1Gi | 200m, 512Mi / 1536Mi |
| ServiceMonitor (`release: monitoring`) | yes | yes |

CPU limits are not set on purpose: a throttled Falco cannot drain the kernel ring buffers and drops events. The upstream CPU limit of one core is removed with `limits.cpu: null`. Replicas and PodDisruptionBudgets do not apply to a DaemonSet.

## Kernel requirements

The modern eBPF probe needs, on every node:

| Requirement | Check on the node |
| --- | --- |
| Kernel with BTF type information | `ls /sys/kernel/btf/vmlinux` |
| BPF ring buffer | `bpftool feature probe kernel \| grep 'map_type ringbuf is available'` |
| BPF tracing programs | `bpftool feature probe kernel \| grep 'program_type tracing is available'` |
| Architecture | x86_64 or aarch64 |

Upstream states that kernels 5.8 and later usually have all of these, and that distributions can backport them to older kernels. Ubuntu 22.04 and later and RHEL 9 kernels ship BTF. For kind, the kernel is the one of the Docker host (on macOS, the Docker Desktop VM); check it there. If a requirement is missing, Falco logs the missing feature at start and the pod restarts in a loop.

## Output and logs

Falco writes each alert as one JSON object per line to stdout. Shape of an alert (abridged, values illustrative):

```json
{"hostname":"node-1","output":"... Shell spawned in a container ...","priority":"Notice","rule":"Terminal shell in container","source":"syscall","tags":["container","shell","mitre_execution"],"time":"2026-11-16T10:00:00.000000000Z","output_fields":{"k8s.ns.name":"dev","k8s.pod.name":"hello-api-7d9c...","container.id":"..."}}
```

The logging toolchain (Alloy) collects the container log like any other pod log and ships it to Loki. Query in Grafana with `{namespace="falco"} | json | priority=~"Critical|Error|Warning"`. Alerting on Falco events is a Loki ruler or Grafana alert rule on that query; this chart does not create one.

## Secrets

None.

## Dependencies

| Toolchain | Why |
| --- | --- |
| monitoring | ServiceMonitor CRD and the Prometheus that scrapes `falco-metrics` (`release: monitoring`) |
| logging | Collects the alerts from stdout. Without it, alerts are only visible with `kubectl logs` |

## Upgrade

1. Read the Falco release notes at <https://github.com/falcosecurity/falco/releases>, the chart `BREAKING-CHANGES.md` and changelog at <https://github.com/falcosecurity/charts/tree/master/charts/falco>, and the rules changes at <https://github.com/falcosecurity/rules/releases>.
2. Change `dependencies[0].version` (and `appVersion`) in `Chart.yaml`, then run `helm dependency update helmcharts/system-charts/falco` and commit the new `Chart.lock`.
3. Check which `falco-rules` and container plugin versions the new Falco build pins (`cmake/modules/rules.cmake` and `CMakeLists.txt` in the Falco repository at the release tag) and update the Rules row in the tables above.
4. Render both profiles and compare. Check that the chart still shadows `/etc/falco/config.d` (the image enables the container plugin there too; loading it twice stops Falco at start).

## Known limitations

- Kyverno: the platform policies `disallow-privileged-containers-audit` and `disallow-privileged-containers-enforce` (kyverno-policies) match only the environment namespaces (`dev` in Audit, `stage` and `prod` in Enforce). They do not apply to the `falco` namespace, so the privileged DaemonSet needs no Kyverno exclusion.
- Least-privileged mode (`driver.modernEbpf.leastPrivileged: true`: capabilities `BPF`, `PERFMON`, `SYS_RESOURCE`, `SYS_PTRACE` instead of `privileged`) is not used. It needs AppArmor set to unconfined and, on SELinux nodes (RHEL family), a policy that allows `bpf()` from a confined container. Both depend on the node OS, so it is left as an option per cluster.
- Falco sees only nodes that match the requirements above. A node without BTF has no runtime detection while its Falco pod crash-loops; alert on the DaemonSet not being fully available.
- The default rules produce some noise on a platform cluster (for example shells from `kubectl exec` during debugging). Tune with exceptions in `customRules`, not by editing the image rules.
