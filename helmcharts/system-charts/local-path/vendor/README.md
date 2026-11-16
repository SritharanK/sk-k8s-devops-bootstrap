# Vendored upstream chart

rancher/local-path-provisioner publishes no Helm repository. Its chart lives in the Git repository, so it is vendored here unchanged.

| Item | Value |
| --- | --- |
| Source | <https://github.com/rancher/local-path-provisioner/archive/refs/tags/v0.0.37.tar.gz> |
| Path in the archive | `local-path-provisioner-0.0.37/deploy/chart/local-path-provisioner` |
| Tag | v0.0.37 (chart version 0.0.37, appVersion v0.0.37) |
| Archive sha256 | `3602edf85bb1513d463073917adc930752177d034e1f944fb8f7610c779a34f6` |
| Vendored on | 2026-11-16 |
| License | Apache License 2.0, see `LICENSE` (copied from the root of the same archive) |

`local-path-provisioner/` is a byte-for-byte copy of the upstream chart directory. Do not edit it; change behaviour through the wrapper values in `../values.yaml` instead.

## Update procedure

1. Pick the new release tag on <https://github.com/rancher/local-path-provisioner/releases> and read its release notes.
2. Download the source archive into an empty working directory outside the repository and record its checksum:

   ```bash
   TAG=v0.0.38
   curl -fsSLO "https://github.com/rancher/local-path-provisioner/archive/refs/tags/${TAG}.tar.gz"
   shasum -a 256 "${TAG}.tar.gz"
   tar -xzf "${TAG}.tar.gz"
   ```

3. Replace `local-path-provisioner/` with the archive's `deploy/chart/local-path-provisioner/` directory, and `LICENSE` with the archive's `LICENSE`. Git history keeps the previous copy.
4. Compare the new `values.yaml` with the old one and adjust the wrapper values for renamed or new keys.
5. Update this file (tag, checksum, date) and, in `../Chart.yaml`, the dependency `version` and `appVersion`. Update `image.tag` in `../values.yaml` to the new release.
6. Run `helm dependency update` in the wrapper chart directory, then lint and render both profiles.
