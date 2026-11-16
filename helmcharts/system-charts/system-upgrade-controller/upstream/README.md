# Upstream release files

Unmodified release assets of rancher/system-upgrade-controller. `crd.yaml` is rendered by `templates/crd.yaml` and must stay in the chart package. `system-upgrade-controller.yaml` is a reference copy for comparison only; the chart does not read it, and `.helmignore` keeps it and this file out of the package.

| Item | Value |
| --- | --- |
| Version | v0.21.1 |
| Release | <https://github.com/rancher/system-upgrade-controller/releases/tag/v0.21.1> |
| Controller image | `rancher/system-upgrade-controller:v0.21.1` |

| File | Source URL | sha256 |
| --- | --- | --- |
| `crd.yaml` | <https://github.com/rancher/system-upgrade-controller/releases/download/v0.21.1/crd.yaml> | `1393ba034e7691273fc519b721a7f72a0cdbef8c7b051c9e408be96090b8478d` |
| `system-upgrade-controller.yaml` | <https://github.com/rancher/system-upgrade-controller/releases/download/v0.21.1/system-upgrade-controller.yaml> | `5b46172058b198f8297c9966aacdcd9da2604f740254f0beae74e61b1ad84eac` |

Both checksums match the asset digests that GitHub shows on the release page.

## Verify the files

```bash
sha256sum crd.yaml system-upgrade-controller.yaml
```

## Compare the templates with a new upstream manifest

Run from the chart directory after replacing the files in `upstream/`. The filter drops the upstream Namespace (Argo CD creates it), the CRD (rendered from `crd.yaml` as is), the chart-only PodDisruptionBudget, labels, pod template annotations and comments, then sorts objects and keys.

```bash
norm='select(.kind != null and .kind != "Namespace" and .kind != "CustomResourceDefinition" and .kind != "PodDisruptionBudget")
  | del(.metadata.labels, .spec.template.metadata.annotations) | ... comments="" | sort_keys(..)'
diff \
  <(yq ea -P "[$norm] | sort_by(.kind + .metadata.name)" upstream/system-upgrade-controller.yaml) \
  <(helm template system-upgrade-controller . -n system-upgrade -f values.yaml -f values-lab.yaml \
      | yq ea -P "[$norm] | sort_by(.kind + .metadata.name)")
```

For v0.21.1 the only differences are the ones this chart adds on purpose: `replicas`, `resources` and `readOnlyRootFilesystem: true` on the Deployment. Any other line in the diff is an upstream change to carry over into `templates/` or `values.yaml` (`controllerEnv`, `image.tag`, `affinity`, `tolerations`).

Also check that the CRD the controller registers at start still equals `crd.yaml`. The controller embeds it from `pkg/crds/yaml/` in the source tree of the same tag.
