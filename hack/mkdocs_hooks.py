# SPDX-License-Identifier: MIT
"""MkDocs hook: links that leave docs/ point to the repository instead.

The Markdown under docs/ is written to be read on the Git host as well, so it
links to files elsewhere in the repository with relative paths, for example
../../ansible/README.md. MkDocs publishes docs/ only: such a link would be
broken on the site and fails `mkdocs build --strict`. Before MkDocs converts
and validates a page, this hook rewrites every relative link whose target is
outside docs/ but inside the repository to an absolute URL:

    <repo_url>/blob/<branch>/<path>   for a file
    <repo_url>/tree/<branch>/<path>   for a directory

The branch is read from edit_uri (edit/<branch>/docs/). Links inside docs/,
absolute URLs, anchors and links in fenced code blocks are left alone. A
target that does not exist is left alone too, so strict mode still reports it
as a broken link.
"""

from __future__ import annotations

import os
import posixpath
import re

_SCHEME = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")
_INLINE = re.compile(r"(\]\()(<?)([^)\s>]+)(>?)((?:\s+\"[^\"]*\")?\))")
_REFDEF = re.compile(r"^(\s{0,3}\[[^\]]+\]:\s*)(<?)(\S+?)(>?)(\s.*)?$")
_FENCE = re.compile(r"^\s{0,3}(`{3,}|~{3,})")
_BRANCH = re.compile(r"^(?:edit|blob|tree)/([^/]+)/")


def _branch(config) -> str:
    match = _BRANCH.match(config.get("edit_uri") or "")
    return match.group(1) if match else "main"


def _rewrite(target: str, page_dir: str, ctx: dict) -> str:
    if not target or target.startswith(("#", "/")) or _SCHEME.match(target):
        return target
    path, sep, anchor = target.partition("#")
    if not path:
        return target
    resolved = posixpath.normpath(posixpath.join(ctx["docs_rel"], page_dir, path))
    if resolved == ctx["docs_rel"] or resolved.startswith(ctx["docs_rel"] + "/"):
        return target
    if resolved == ".." or resolved.startswith("../"):
        return target
    absolute = os.path.join(ctx["repo_root"], *resolved.split("/"))
    if os.path.isdir(absolute):
        kind = "tree"
    elif os.path.isfile(absolute):
        kind = "blob"
    else:
        return target
    rel = "" if resolved == "." else resolved
    url = f"{ctx['repo_url']}/{kind}/{ctx['branch']}/{rel}".rstrip("/")
    return url + sep + anchor


def on_page_markdown(markdown, page, config, files):  # noqa: ARG001 (MkDocs hook signature)
    repo_url = (config.get("repo_url") or "").rstrip("/")
    if not repo_url:
        return markdown
    # docs_dir is absolute after MkDocs loads the configuration, and docs/
    # sits at the repository root.
    docs_dir = os.path.abspath(config["docs_dir"])
    repo_root = os.path.dirname(docs_dir)
    ctx = {
        "repo_url": repo_url,
        "branch": _branch(config),
        "repo_root": repo_root,
        "docs_rel": os.path.basename(docs_dir),
    }
    page_dir = posixpath.dirname(page.file.src_uri)

    def inline(match: re.Match) -> str:
        new = _rewrite(match.group(3), page_dir, ctx)
        return match.group(1) + match.group(2) + new + match.group(4) + match.group(5)

    out = []
    fence = None
    for line in markdown.split("\n"):
        opener = _FENCE.match(line)
        if fence is None and opener:
            fence = opener.group(1)
        elif fence is not None:
            if opener and opener.group(1)[0] == fence[0] and len(opener.group(1)) >= len(fence):
                fence = None
        else:
            ref = _REFDEF.match(line)
            if ref:
                new = _rewrite(ref.group(3), page_dir, ctx)
                line = ref.group(1) + ref.group(2) + new + ref.group(4) + (ref.group(5) or "")
            else:
                line = _INLINE.sub(inline, line)
        out.append(line)
    return "\n".join(out)
