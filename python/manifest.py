"""Stage 4 helper: generate repo's default.xml from a verified inventory.

This is the file `repo init -u` fetches, and it is what turns ~57 unrelated GitLab
repositories back into one coherent SDK tree.

HARD RULES ENCODED HERE
-----------------------
Each of these was a real multi-hour debugging session recorded in the SOP's
troubleshooting section. They are enforced in code so they cannot recur:

  1. <remote fetch> must be a COMPLETE URL to the GitLab group. A relative '..'
     makes repo synthesise URLs that do not exist, and the resulting error
     ("repository not found", or an HTML redirect to /users/sign_in) points at
     authentication rather than at the real cause.

  2. No <project path> may start with '.'. repo rejects it as a "bad component",
     and the half-written .repo directory left behind cannot be repaired.

  3. Top-level symlinks must be <linkfile>, never committed files. Otherwise the
     content is duplicated and repo fights the addons checkout over that path.

  4. revision must be a branch that actually exists in every repo. Stage 3 creates
     everything on 'main' precisely so this holds uniformly; a mismatch produces
     ManifestInvalidRevisionError at checkout time, after a full fetch has already
     completed.
"""

from __future__ import annotations

import json
from pathlib import Path
from xml.sax.saxutils import quoteattr


def generate_manifest(
    inventory_path: str,
    host: str,
    group: str,
    protocol: str = "ssh",
    revision: str = "main",
    sync_j: int = 8,
) -> str:
    """Build default.xml as a string.

    protocol defaults to ssh because that is where the previous migration finally
    landed after exhausting the HTTP options. HTTP against private GitLab repos
    requires a PAT, and supplying it means either embedding credentials in the URL
    (which repo then persists into .repo/manifests.git/config) or maintaining a
    ~/.netrc on every developer machine. An SSH key makes the whole class of
    "HTTP Basic: Access denied" problems disappear.

    Returns the XML rather than writing it, so callers can diff it against the
    existing manifest before overwriting.
    """
    inv = json.loads(Path(inventory_path).read_text(encoding="utf-8"))

    # Rule 1: always a complete group URL.
    if protocol == "ssh":
        fetch = f"ssh://git@{host}/{group}"
    else:
        fetch = f"http://{host}/{group}"

    # Attribute each top-level symlink to the project that owns its target, so the
    # <linkfile> can be emitted as a child of the right <project>. repo resolves
    # linkfile src relative to the owning project's path, so the owner must be
    # correct or the created symlink dangles.
    projects = inv["projects"]
    by_path = {p["path"]: p for p in projects}
    links_for: dict[str, list[dict]] = {}

    for link in inv.get("top_level_symlinks", []):
        target = link["target"].lstrip("./")
        owner = None
        # Longest path first: 'docs/cn' must win over 'docs' for a target inside it.
        for p in sorted(by_path, key=len, reverse=True):
            if target == p or target.startswith(p + "/"):
                owner = p
                break
        if owner:
            # src is relative to the owning project; dest is relative to SDK root.
            src = target[len(owner):].lstrip("/") or "."
            links_for.setdefault(owner, []).append(
                {"src": src, "dest": link["dest"]}
            )

    out = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        "<manifest>",
        f"  <remote name=\"origin\" fetch={quoteattr(fetch)} />",
        # Rule 4: one uniform revision across every project.
        f'  <default revision="{revision}" remote="origin" sync-j="{sync_j}" />',
        "",
    ]

    for p in sorted(projects, key=lambda x: x["path"]):
        # Rule 2: repo would reject a dot-leading path outright.
        if p["path"].startswith("."):
            continue
        # quoteattr everywhere: paths may contain characters that need escaping,
        # and hand-built XML is a classic source of silent corruption.
        name = quoteattr(p["gitlab_name"])
        path = quoteattr(p["path"])
        kids = links_for.get(p["path"], [])
        if kids:
            out.append(f"  <project name={name} path={path}>")
            for k in kids:
                # Rule 3: reproduce the symlink instead of committing its content.
                out.append(
                    f"    <linkfile src={quoteattr(k['src'])} "
                    f"dest={quoteattr(k['dest'])} />"
                )
            out.append("  </project>")
        else:
            out.append(f"  <project name={name} path={path} />")

    # Orphan files need a home. They are checked out at the SDK root by a dedicated
    # addons repo. Symlink destinations are excluded because <linkfile> already
    # covers those.
    orphans = [o for o in inv.get("orphan_files", [])
               if o not in {l["dest"] for l in inv.get("top_level_symlinks", [])}]
    if orphans:
        out += [
            "",
            "  <!-- orphan files not covered by any upstream project -->",
            '  <project name="sdk-addons" path="." />',
        ]

    out += ["", "</manifest>"]
    return "\n".join(out) + "\n"
