#!/usr/bin/env python3
"""Resolve the Jenkins plugin lock file for one LTS release.

Reads the top-level plugin list (plugins.in.txt), fetches the update center
data that the Jenkins project publishes for the given core version, resolves
every required (non-optional) dependency, and writes plugins.txt with one
exact `id:version` per line. The run fails when:

- a plugin is missing from the update center,
- a resolved version needs a newer core than the target release,
- a resolved version is below the minimum another plugin requires,
- a resolved version matches an active security warning.

Usage (from the repository root):

    python3 ci/jenkins/scripts/resolve-plugins.py --core 2.580.2

Only the Python standard library is used. Pass --update-center-json to work
from a downloaded copy instead of the network.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.request
from pathlib import Path

ROLE_FILES = Path("ansible/roles/install_jenkins/files")
UPDATE_CENTER = "https://updates.jenkins.io/update-center.actual.json?version={core}"


def version_key(version: str) -> list:
    """Order Jenkins plugin versions well enough to compare minimums.

    Incremental versions such as 4560.vc25b_83890c34 compare by their leading
    number, which is how the update center orders them as well.
    """
    key = []
    for part in re.split(r"[.\-]", version):
        if part.isdigit():
            key.append((0, int(part)))
        else:
            key.append((1, part))
    return key


def load_update_center(core: str, path: str | None) -> dict:
    if path:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    url = UPDATE_CENTER.format(core=core)
    request = urllib.request.Request(url, headers={"User-Agent": "resolve-plugins"})
    with urllib.request.urlopen(request, timeout=60) as response:  # noqa: S310 (fixed https URL)
        return json.load(response)


def read_top_level(path: Path) -> list[str]:
    plugins = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if line:
            plugins.append(line)
    return plugins


def warnings_for(update_center: dict, plugin: str, version: str) -> list[str]:
    hits = []
    for warning in update_center.get("warnings", []):
        if warning.get("type") != "plugin" or warning.get("name") != plugin:
            continue
        for affected in warning.get("versions", []):
            pattern = affected.get("pattern")
            if pattern and re.fullmatch(pattern, version):
                hits.append(warning.get("id", "unknown") + " " + warning.get("url", ""))
    return hits


def resolve(update_center: dict, core: str, top_level: list[str]) -> dict[str, str]:
    plugins = update_center["plugins"]
    resolved: dict[str, str] = {}
    minimums: dict[str, list[tuple[str, str]]] = {}
    errors: list[str] = []
    queue = list(top_level)
    while queue:
        name = queue.pop()
        if name in resolved:
            continue
        entry = plugins.get(name)
        if entry is None:
            errors.append(f"{name}: not in the update center for core {core}")
            continue
        resolved[name] = entry["version"]
        if version_key(entry.get("requiredCore", "0")) > version_key(core):
            errors.append(f"{name} {entry['version']}: requires core {entry['requiredCore']}")
        for dependency in entry.get("dependencies", []):
            if dependency.get("optional"):
                continue
            minimums.setdefault(dependency["name"], []).append((name, dependency["version"]))
            queue.append(dependency["name"])

    for name, required in minimums.items():
        if name not in resolved:
            continue
        for requester, minimum in required:
            if version_key(resolved[name]) < version_key(minimum):
                errors.append(f"{name} {resolved[name]}: {requester} needs at least {minimum}")

    for name, version in resolved.items():
        for hit in warnings_for(update_center, name, version):
            errors.append(f"{name} {version}: security warning {hit}")

    if errors:
        for error in sorted(errors):
            print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
    return resolved


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--core", required=True, help="Jenkins LTS version, for example 2.580.2")
    parser.add_argument("--input", default=str(ROLE_FILES / "plugins.in.txt"))
    parser.add_argument("--output", default=str(ROLE_FILES / "plugins.txt"))
    parser.add_argument("--update-center-json", help="use a local copy of update-center.actual.json")
    args = parser.parse_args()

    if not re.fullmatch(r"\d+\.\d+\.\d+", args.core):
        parser.error("--core must be an LTS version such as 2.580.2")

    update_center = load_update_center(args.core, args.update_center_json)
    served_core = update_center.get("core", {}).get("version")
    if served_core != args.core:
        print(f"error: update center serves core {served_core}, expected {args.core}", file=sys.stderr)
        sys.exit(1)

    top_level = read_top_level(Path(args.input))
    resolved = resolve(update_center, args.core, top_level)

    lines = [
        f"# Jenkins {args.core}: exact plugin versions, including every required dependency.",
        "# Do not edit by hand. Edit plugins.in.txt, then run from the repository root:",
        f"#   python3 ci/jenkins/scripts/resolve-plugins.py --core {args.core}",
    ]
    lines += [f"{name}:{resolved[name]}" for name in sorted(resolved)]
    Path(args.output).write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"{len(resolved)} plugins ({len(top_level)} top-level) written to {args.output}")


if __name__ == "__main__":
    main()
