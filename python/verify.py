"""Stage 2 of 4: read-only assertions. The review gate between finding and doing.

WHY THIS STAGE EXISTS
---------------------
Stage 1 gathered facts. Stage 3 will create GitLab projects and push commits. This
stage sits between them and refuses to let stage 3 run on an incomplete inventory.

Its single most important behaviour is that it FAILS when it does not know something,
rather than picking a default. The failure mode this prevents is specific and was
observed on the real SDK: 322 Rockchip PDFs and 27 cross-compile scripts were
matched by .gitignore rules. A tool that "helpfully" defaults to excluding ignored
files would have dropped all of them, reported success, and nobody would have
noticed until someone needed a datasheet or tried to cross-compile mpp months later.

Silent incompleteness is far worse than a loud failure. So: no defaults, no
guessing. Every ignored file needs an explicit keep or drop rule with a reason.
"""

from __future__ import annotations

import fnmatch
import json
import os
from pathlib import Path


class VerifyError(Exception):
    """Raised for malformed inventories, as opposed to inventories with problems.

    A problem (unadjudicated file, name collision) is expected and reported in the
    returned list. This exception is for an inventory that cannot be read at all.
    """


def _match(path: str, pattern: str) -> bool:
    """Glob-match a path against an adjudication pattern.

    fnmatch's '*' already spans '/' (unlike a shell glob), so '**' would be
    redundant. We normalise '**' to '*' so that patterns can be written in the
    familiar 'docs/cn/**/*.pdf' style and still behave as expected.
    """
    return fnmatch.fnmatch(path, pattern.replace("**", "*"))


def adjudicate(path: str, rules: list[dict]) -> str | None:
    """Resolve a path to 'keep', 'drop', or None if no rule matches.

    First match wins, so rules must be ordered most-specific-first. This lets you
    write a broad rule then carve out exceptions above it, e.g. keep one required
    firmware blob before a rule dropping everything else in that directory.

    Returning None (rather than a default) is the whole point: it propagates up to
    verify() as a hard failure.
    """
    for rule in rules:
        if _match(path, rule["pattern"]):
            return rule["action"]
    return None


def verify(inventory_path: str, max_file_mb: int | None = None) -> list[str]:
    """Run every assertion. Returns a list of problems; empty means ready.

    We collect all problems rather than raising on the first one, so that a single
    run tells you everything that needs fixing instead of forcing you to iterate
    one error at a time.

    The six checks map directly to failure modes hit on real migrations; several
    are recorded in the SOP's troubleshooting section as multi-hour debugging
    sessions that a pre-flight assertion would have prevented outright.
    """
    inv = json.loads(Path(inventory_path).read_text(encoding="utf-8"))
    problems: list[str] = []

    projects = inv["projects"]
    managed = [p["path"] for p in projects]
    rules = inv.get("ignored_adjudication", [])

    # CHECK 1: name collisions.
    # Flattening '/' to '-' can map two distinct paths onto one GitLab project.
    # Unchecked, the second push force-overwrites the first and you get a repo whose
    # contents are simply wrong, with no error anywhere.
    collisions = inv["stats"].get("name_collisions", [])
    if collisions:
        problems.append(
            f"GitLab name collisions after flattening: {collisions}. "
            "Disambiguate with a path-derived suffix."
        )

    # CHECK 2: nested repositories must be excluded by their parent.
    # rk3576 has docs/ -> docs/cn/ -> docs/cn/RK3576/. If the parent commits its
    # children's files, `repo sync` then tries to check out the child into a
    # directory the parent has already populated.
    for p in projects:
        kids = [m for m in managed
                if m != p["path"] and m.startswith(p["path"] + "/")]
        declared = set(p.get("excluded_subpaths", []))
        missing = [k for k in kids if k not in declared]
        if missing:
            problems.append(
                f"project '{p['path']}' nests {missing} but does not exclude them; "
                "the parent commit would swallow the child repo's files."
            )

    # CHECK 3: every ignored file must be explicitly adjudicated.
    # This is the check that protects against silent content loss. See module
    # docstring for why defaulting is not acceptable here.
    unadjudicated: list[str] = []
    for cand in inv.get("ignored_candidates", []):
        full = f"{cand['project']}/{cand['file']}"
        if adjudicate(full, rules) is None:
            unadjudicated.append(full)
    if unadjudicated:
        # Truncate the display; the full list is derivable from inventory.json.
        shown = unadjudicated[:15]
        problems.append(
            f"{len(unadjudicated)} ignored file(s) have no keep/drop rule. "
            f"Refusing to guess (silent loss risk). First {len(shown)}:\n    "
            + "\n    ".join(shown)
        )

    # CHECK 4: oversized files need LFS, or an explicitly raised server limit.
    # Without this, the push fails deep into stage 3 after most projects are already
    # pushed, leaving a half-migrated GitLab group.
    if max_file_mb is not None:
        too_big = [f for f in inv.get("large_files", []) if f["size_mb"] > max_file_mb]
        lfs_ok = any(p.get("needs_lfs") for p in projects)
        if too_big and not lfs_ok:
            problems.append(
                f"{len(too_big)} file(s) exceed {max_file_mb}MB with no LFS enabled: "
                f"{[f['path'] for f in too_big[:5]]}"
            )

    # CHECK 5: manifest legality.
    # repo hard-rejects any project path beginning with '.' ("bad component"), a
    # guard against a project clobbering the .repo control directory. This surfaces
    # at `repo init` time on every developer's machine, and the half-initialised
    # .repo left behind is not recoverable - the directory must be deleted.
    for p in projects:
        if p["path"].startswith("."):
            problems.append(
                f"project path '{p['path']}' starts with '.'; repo will reject it "
                "(bad component)."
            )

    # CHECK 6: orphans must be routed somewhere.
    # A file covered by no project, no <linkfile>, and no rule simply does not exist
    # after migration. On rk3576 that would have silently discarded the debian/ and
    # ubuntu/ trees - 2.3GB containing the vendor's actual board customisation.
    orphans = inv.get("orphan_files", [])
    link_dests = {l["dest"] for l in inv.get("top_level_symlinks", [])}
    unrouted = [o for o in orphans
                if o not in link_dests and adjudicate(o, rules) is None]
    if unrouted:
        problems.append(
            f"{len(unrouted)} orphan file(s) are neither a <linkfile> nor covered by "
            f"a rule; they would be LOST. First 10: {unrouted[:10]}"
        )

    return problems


def coverage_report(inventory_path: str) -> str:
    """Render a human-readable Markdown summary of the inventory.

    Printed on every verify run, pass or fail, so the numbers can be eyeballed
    against expectations. The unclassified count is the number to watch: it must
    reach zero before stage 3 may run.
    """
    inv = json.loads(Path(inventory_path).read_text(encoding="utf-8"))
    s = inv["stats"]
    rules = inv.get("ignored_adjudication", [])

    keep = drop = uncls = 0
    for cand in inv.get("ignored_candidates", []):
        a = adjudicate(f"{cand['project']}/{cand['file']}", rules)
        if a == "keep":
            keep += 1
        elif a == "drop":
            drop += 1
        else:
            uncls += 1

    lines = [
        "# Coverage Report",
        "",
        f"- diagnosis: **{inv['diagnosis']}**",
        f"- projects: {s['project_count']} "
        f"(broken symlinks: {s['broken_symlinks']}, real: {s['real_repos']})",
        f"- orphan files: {s['orphan_file_count']}",
        f"- large files (>50MB): {s['large_file_count']}",
        f"- ignored candidates: {s['ignored_candidate_count']}",
        f"    - keep: {keep}   drop: {drop}   **unclassified: {uncls}**",
        f"- name collisions: {s.get('name_collisions') or 'none'}",
        f"- nested repo parents: {s.get('nested_repo_parents') or 'none'}",
    ]
    return "\n".join(lines) + "\n"
