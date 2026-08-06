"""Stage 1 of 4: read-only forensics. Turns a damaged SDK tree into inventory.json.

WHY THIS MODULE IS READ-ONLY, AND MUST STAY THAT WAY
----------------------------------------------------
The whole point of splitting extract from execute is that fact-finding must never
be able to damage the evidence. A vendor SDK tarball is often the ONLY copy of the
tree; the original git history is already gone. If a forensics pass corrupts it,
there is nothing to fall back on.

So this module obeys one hard rule: it never writes anything inside the SDK.
The tricky part is querying .gitignore state, which normally needs a real git repo.
The workaround (see audit_ignored) is `git init --bare` into a temp dir plus
--work-tree pointing at the SDK, so git can answer ignore questions without a
single byte being written into the tree under investigation.

OUTPUT CONTRACT
---------------
inventory.json is the stable contract between the four stages. It is deliberately
plain JSON: human-readable, diffable, reviewable in a pull request, and comparable
across different SDK generations. Every later stage reads it and makes no fresh
judgements of its own.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
from dataclasses import asdict, dataclass, field
from pathlib import Path

# Bumped whenever inventory.json's shape changes, so later stages can refuse to
# consume a format they do not understand.
SCHEMA_VERSION = 1

# Files above this size are flagged as LFS candidates. 50MB is well under
# GitLab's typical hard limits but above anything that belongs in plain git.
LFS_THRESHOLD_MB = 50


@dataclass
class Project:
    """One reconstructable git repository within the SDK tree.

    A "project" here means a directory that used to be an independent git repo
    managed by `repo`. We detect them by the .git entries left behind, even when
    those entries are broken symlinks pointing into a .repo/ that no longer exists.
    """

    path: str                      # Path relative to the SDK root, e.g. "external/mpp".
    gitlab_name: str               # Flattened for GitLab: '/' -> '-'.
    git_entry: str                 # 'broken-symlink' | 'real-dir' | 'gitfile' | 'unknown'
    symlink_target: str | None = None   # For broken symlinks: the fossil evidence.
    size_mb: int = 0               # Approx payload size, excluding download caches.
    needs_lfs: bool = False        # True if this project contains an oversized file.
    excluded_subpaths: list[str] = field(default_factory=list)
    """Nested child repos this project must NOT commit.

    Example: docs/ contains docs/cn/ which is itself a separate repo. Without this
    exclusion the docs/ commit would swallow all of docs/cn/'s files, and the child
    repo's own checkout would then conflict with them.
    """


@dataclass
class Inventory:
    """The complete read-only findings. Serialised to inventory.json."""

    schema_version: int
    sdk_root: str
    detector: str
    diagnosis: str                      # Which damage class this tree falls into.
    projects: list[dict]
    orphan_files: list[str]             # Files no project covers.
    large_files: list[dict]             # LFS candidates.
    top_level_symlinks: list[dict]      # Become <linkfile>, never committed.
    ignored_candidates: list[dict]      # Files .gitignore would silently drop.
    ignored_adjudication: list[dict]    # Human-authored keep/drop rules.
    stats: dict


def _run(cmd: list[str], cwd: str | None = None) -> tuple[int, str]:
    """Run a command and capture stdout, never raising on non-zero exit.

    Many probes here are expected to fail sometimes (a missing dir, a git command
    on a non-repo). Callers decide what a failure means, so we return the exit
    code rather than throwing.
    """
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, check=False)
    return p.returncode, p.stdout


def classify_git_entry(p: Path) -> tuple[str, str | None]:
    """Determine what a .git entry actually IS. Returns (kind, symlink_target).

    This function exists because `find -name ".git"` is actively misleading: it
    reports broken symlinks and real repositories identically. On the rk3576 SDK,
    find reported 55 ".git" entries and every single one was a dangling symlink
    into a .repo/ directory the vendor had deleted before shipping. Acting on that
    count without classifying first would mean assuming 55 recoverable histories
    when in fact there were zero.

    Order matters: the is_symlink() check must come first, because a symlink that
    happens to resolve to a directory would otherwise be misreported as 'real-dir'
    and we would lose the target path, which is our only fossil evidence.
    """
    if p.is_symlink():
        target = os.readlink(p)
        # p.exists() follows the link, so False here means the link is dangling.
        return ("real-dir" if p.exists() else "broken-symlink"), target
    if p.is_dir():
        return "real-dir", None
    if p.is_file():
        # A plain file named .git is a "gitfile": a pointer like
        # "gitdir: /path/to/real/repo", used by worktrees and submodules.
        return "gitfile", None
    return "unknown", None


def diagnose(sdk_root: Path) -> tuple[str, list[tuple[str, str, str | None]]]:
    """Classify the damage and enumerate every project. Returns (diagnosis, entries).

    The diagnosis drives everything downstream, because the correct procedure is
    completely different per class:

      healthy              .repo present with real repos. Parse the manifests
                           normally; do not use this tool.
      repo-meta-deleted    .repo is gone but the object stores survive. History is
                           SALVAGEABLE. Try to rescue it before rebuilding, because
                           a snapshot rebuild throws it away irreversibly.
      metadata-stripped    Only broken symlinks remain. History does not exist
                           anywhere. Snapshot rebuild is the only option.

    Getting this wrong in the 'repo-meta-deleted' direction is the expensive
    mistake: you would destroy recoverable history for no reason.
    """
    entries: list[tuple[str, str, str | None]] = []

    # We shell out to `find` rather than relying solely on os.walk because os.walk
    # classifies a dangling symlink inconsistently across layouts (it may appear in
    # dirnames or filenames, or be skipped). `find -name` sees them all uniformly.
    rc, out = _run(["find", str(sdk_root), "-name", ".git"])
    seen: set[str] = set()
    for line in out.splitlines():
        if not line.strip():
            continue
        full = Path(line)
        rel = str(full.parent.relative_to(sdk_root))
        if rel in seen:
            continue
        kind, target = classify_git_entry(full)
        entries.append((rel, kind, target))
        seen.add(rel)

    entries.sort()
    broken = sum(1 for _, k, _ in entries if k == "broken-symlink")
    real = sum(1 for _, k, _ in entries if k in ("real-dir", "gitfile"))
    has_repo = (sdk_root / ".repo").exists()

    if has_repo and real:
        d = "healthy: .repo present with real repos - use standard manifest parsing"
    elif not has_repo and real and not broken:
        d = "repo-meta-deleted: history SURVIVES, attempt salvage before rebuilding"
    elif broken and not real:
        d = "metadata-stripped: history is GONE, snapshot rebuild required"
    else:
        d = f"mixed: {broken} broken / {real} real - inspect individually"
    return d, entries


def flatten_name(path: str) -> str:
    """Convert an SDK-relative path into a flat GitLab project name.

    GitLab projects are created flat inside one group rather than as nested
    subgroups, so 'external/security/bin' becomes 'external-security-bin'. This can
    collide (two different paths mapping to one name); verify.py detects that and
    refuses to continue rather than letting one repo silently overwrite another.
    """
    return path.replace("/", "-")


def find_orphans(sdk_root: Path, managed: list[str]) -> list[str]:
    """List files that no project covers. These would be LOST in a naive migration.

    Orphans are the files the vendor added outside of any repo-managed project.
    On rk3576 these turned out to be the debian/ and ubuntu/ trees (2.3GB, zero git
    entries) which contain the vendor's actual board customisation, plus the six
    top-level symlinks.

    Performance note: we prune managed subtrees via the `dirs[:] = ...` mutation
    (only legal with topdown=True). Without pruning, this would walk all 171k files
    in the SDK; with it, only the small uncovered remainder is visited.
    """

    def is_managed(rel: str) -> bool:
        # Prefix match on path segments. The os.sep guard prevents 'docs' from
        # wrongly claiming a sibling directory named 'docs-extra'.
        return any(rel == m or rel.startswith(m + os.sep) for m in managed)

    orphans: list[str] = []
    for root, dirs, files in os.walk(sdk_root, topdown=True):
        rel = os.path.relpath(root, sdk_root)
        rel = "" if rel == "." else rel

        # This directory is itself part of a project: skip it entirely.
        if rel and is_managed(rel):
            dirs[:] = []
            files[:] = []
            continue

        # Do not descend into managed children.
        dirs[:] = [d for d in dirs
                   if not is_managed(os.path.join(rel, d) if rel else d)]

        for f in files:
            fp = os.path.join(rel, f) if rel else f
            if not is_managed(fp):
                orphans.append(fp)
    return sorted(orphans)


def audit_ignored(sdk_root: Path, projects: list[str]) -> list[dict]:
    """List every file .gitignore would silently exclude, per project.

    THIS IS THE MOST IMPORTANT FUNCTION IN THE TOOL.

    A snapshot rebuild does `git init && git add . && git commit`. That respects
    .gitignore, but the SDK's .gitignore files were written for the UPSTREAM
    development workflow, not for your snapshot. Upstream can force-add files with
    `git add -f` and they stay tracked forever after; you have no history, so you
    must re-make every one of those decisions explicitly.

    On rk3576 this found 1210 ignored files. Both extremes were present at once:
      MUST KEEP: 322 Rockchip PDFs under docs/ (unreproducible), 27 cross-compile
                 scripts under external/mpp/build/, the Mali GPU firmware blob.
      MUST DROP: 600 files of buildroot/dl download cache (2.5GB, re-downloadable),
                 96 .o.cmd kernel build leftovers in external/rkwifibt.
    Because both exist in one tree, no global policy is correct. Only per-file
    adjudication is.

    Why we ask git instead of parsing .gitignore ourselves: git prunes excluded
    directories and never descends into them, which makes nested re-include rules
    unreachable. external/mpp is the proof - its root .gitignore has "/build", and
    build/.gitignore has "!*.bash" trying to rescue the scripts, but the rescue can
    never fire. Any text-parsing implementation gets this backwards.

    Note this returns CANDIDATES, not decisions. Classifying them is a human
    engineering judgement (a PDF is content; a .o.cmd is a build artifact), and
    verify.py refuses to proceed until every one has a rule.
    """
    probe = tempfile.mkdtemp(prefix="sdk-reclaim-probe-")
    out: list[dict] = []
    try:
        for p in projects:
            wt = sdk_root / p
            if not wt.is_dir():
                continue
            # A bare repo in /tmp plus --work-tree lets git evaluate ignore rules
            # against the SDK without creating a .git inside it.
            gd = os.path.join(probe, p.replace("/", "_") + ".git")
            _run(["git", "init", "-q", "--bare", gd])
            # -o lists untracked files; -i restricts that to the ignored ones.
            # Since nothing is tracked in a fresh repo, this yields exactly the set
            # `git add .` would skip.
            rc, listing = _run([
                "git", f"--git-dir={gd}", f"--work-tree={wt}",
                "ls-files", "-o", "-i", "--exclude-standard",
            ])
            for line in listing.splitlines():
                if line.strip():
                    out.append({"project": p, "file": line.strip()})
    finally:
        # Always clean the probe dir, even if a git call blew up partway through.
        shutil.rmtree(probe, ignore_errors=True)
    return out


def collect_large_files(sdk_root: Path, threshold_mb: int) -> list[dict]:
    """Find files too big for plain git, sorted largest first.

    These decide whether LFS is required. On rk3576 there are 9 files over 100MB,
    the largest being a 1.3GB prebuilt Debian rootfs tarball. Pushing those without
    LFS either gets rejected outright or produces a repository nobody can clone in
    reasonable time, since git cannot delta-compress an already-compressed .tar.xz.
    """
    rc, out = _run([
        "find", str(sdk_root), "-type", "f",
        "-size", f"+{threshold_mb}M", "-printf", "%s\t%p\n",
    ])
    files = []
    for line in out.splitlines():
        if "\t" not in line:
            continue
        size, path = line.split("\t", 1)
        files.append({
            "path": str(Path(path).relative_to(sdk_root)),
            "size_mb": int(size) // (1024 * 1024),
        })
    return sorted(files, key=lambda f: -f["size_mb"])


def collect_top_symlinks(sdk_root: Path) -> list[dict]:
    """Record top-level symlinks, which must become <linkfile> and NOT commits.

    On rk3576: build.sh, Makefile, rkflash.sh, README.md, common, kernel. They point
    into subprojects (e.g. build.sh -> device/rockchip/common/scripts/build.sh).

    Committing them into an addons repo would be wrong twice over: the file content
    would be duplicated, and repo would then fight the addons checkout over who owns
    that path. Declaring them as <linkfile> makes repo recreate the symlink after
    sync, which is what the original SDK actually had.
    """
    links = []
    for entry in sorted(sdk_root.iterdir()):
        if entry.is_symlink():
            links.append({"dest": entry.name, "target": os.readlink(entry)})
    return links


def compute_nested_exclusions(managed: list[str]) -> dict[str, list[str]]:
    """Map each parent project to the child projects nested inside it.

    On rk3576, docs/ contains docs/cn/ which contains docs/cn/RK3576/ - three
    separate repos stacked three levels deep. If docs/ commits everything under
    itself, it absorbs both children's files, and after `repo sync` the child
    checkouts collide with the copies the parent already placed there.
    """
    nested: dict[str, list[str]] = {}
    for parent in managed:
        kids = [m for m in managed if m != parent and m.startswith(parent + "/")]
        if kids:
            nested[parent] = sorted(kids)
    return nested


def extract(sdk_root_str: str, detector: str = "rockchip") -> Inventory:
    """Run the full read-only forensics pass and return the assembled Inventory.

    Sequence: diagnose the damage class, enumerate projects, then gather the four
    categories of thing that a naive migration loses (orphans, ignored files,
    oversized files, symlinks).

    Makes no decisions and mutates nothing. Every judgement call is deferred to a
    human reviewing inventory.json, which is enforced by verify.py.
    """
    sdk_root = Path(sdk_root_str).resolve()
    diag, entries = diagnose(sdk_root)

    managed = [rel for rel, _, _ in entries]
    nested = compute_nested_exclusions(managed)
    large = collect_large_files(sdk_root, LFS_THRESHOLD_MB)
    large_set = {f["path"] for f in large}

    projects: list[dict] = []
    for rel, kind, target in entries:
        # --exclude=dl skips buildroot's download cache so the reported size
        # reflects the actual git payload rather than 2.5GB of re-fetchable tarballs.
        rc, du = _run(["du", "-sm", "--exclude=dl", str(sdk_root / rel)])
        size_mb = int(du.split()[0]) if du.split() else 0
        needs_lfs = any(f.startswith(rel + "/") for f in large_set)
        projects.append(asdict(Project(
            path=rel,
            gitlab_name=flatten_name(rel),
            git_entry=kind,
            symlink_target=target,
            size_mb=size_mb,
            needs_lfs=needs_lfs,
            excluded_subpaths=nested.get(rel, []),
        )))

    orphans = find_orphans(sdk_root, managed)
    ignored = audit_ignored(sdk_root, managed)

    # Detect flattening collisions now so verify.py can report them as a hard error.
    from collections import Counter
    name_counts = Counter(p["gitlab_name"] for p in projects)
    collisions = sorted(n for n, c in name_counts.items() if c > 1)

    inv = Inventory(
        schema_version=SCHEMA_VERSION,
        sdk_root=str(sdk_root),
        detector=detector,
        diagnosis=diag,
        projects=projects,
        orphan_files=orphans,
        large_files=large,
        top_level_symlinks=collect_top_symlinks(sdk_root),
        ignored_candidates=ignored,
        # Intentionally empty: only a human can classify these, and verify.py
        # fails until they have.
        ignored_adjudication=[],
        stats={
            "project_count": len(projects),
            "broken_symlinks": sum(1 for p in projects
                                   if p["git_entry"] == "broken-symlink"),
            "real_repos": sum(1 for p in projects
                              if p["git_entry"] in ("real-dir", "gitfile")),
            "orphan_file_count": len(orphans),
            "large_file_count": len(large),
            "ignored_candidate_count": len(ignored),
            "name_collisions": collisions,
            "nested_repo_parents": sorted(nested.keys()),
        },
    )
    return inv


def write_inventory(inv: Inventory, out_path: str) -> None:
    """Serialise the Inventory to JSON.

    indent=2 and ensure_ascii=False are deliberate: the file is meant to be read by
    a human and diffed in review, and the SDK contains Chinese filenames that would
    otherwise be mangled into unreadable escape sequences.
    """
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump(asdict(inv), fh, indent=2, ensure_ascii=False)
        fh.write("\n")
