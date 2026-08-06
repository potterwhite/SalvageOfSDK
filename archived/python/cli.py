#!/usr/bin/env python3
"""sdk-reclaim - forensics and reconstruction for SDKs whose repo metadata is gone.

Four stages, deliberately separated so that fact-finding can never mutate the tree:

    extract   (read-only)  SDK tree      -> inventory.json
    verify    (read-only)  inventory     -> assertions, non-zero exit on problems
    execute   (idempotent) inventory     -> GitLab projects + pushes   [not implemented]
    manifest  (read-only)  inventory     -> default.xml

Why the split: mixing judgement with mutation makes failures destructive and
unreplayable, and hides every decision inside a runtime loop where no human can
review it. inventory.json is the reviewable, diffable contract between stages.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def cmd_extract(args: argparse.Namespace) -> int:
    """Stage 1: scan the SDK and write inventory.json.

    Prints the headline numbers so the diagnosis can be sanity-checked immediately.
    The most important line is the diagnosis itself: if it says 'repo-meta-deleted'
    rather than 'metadata-stripped', STOP - git history still exists in that tree
    and a snapshot rebuild would destroy it irreversibly.

    Imports are deferred into each command so that `--help` stays instant and a
    syntax error in one stage cannot break the others.
    """
    from .extract import extract, write_inventory

    inv = extract(args.sdk_root, detector=args.detector)
    write_inventory(inv, args.output)

    s = inv.stats
    print(f"diagnosis: {inv.diagnosis}")
    print(f"  projects              : {s['project_count']}")
    print(f"    broken symlinks     : {s['broken_symlinks']}")
    print(f"    real repos          : {s['real_repos']}")
    print(f"  orphan files          : {s['orphan_file_count']}")
    print(f"  large files (>50MB)   : {s['large_file_count']}")
    print(f"  ignored candidates    : {s['ignored_candidate_count']}")
    if s.get("name_collisions"):
        print(f"  !! name collisions    : {s['name_collisions']}")
    if s.get("nested_repo_parents"):
        print(f"  nested repo parents   : {s['nested_repo_parents']}")
    print(f"\nwrote {args.output}")
    print("\nNext: adjudicate every ignored file as keep/drop in "
          "'ignored_adjudication', then run `sdk-reclaim verify`.")
    return 0


def cmd_verify(args: argparse.Namespace) -> int:
    """Stage 2: assert the inventory is complete. Exit 1 if not.

    Expected to FAIL on a freshly extracted inventory, because ignored_adjudication
    starts empty and every ignored file needs an explicit keep/drop rule. That
    failure is the tool working correctly, not a bug.

    Exits non-zero so this can gate a CI pipeline or a shell && chain.
    """
    from .verify import coverage_report, verify

    problems = verify(args.inventory, max_file_mb=args.max_file_mb)
    print(coverage_report(args.inventory))
    if problems:
        print("VERIFY FAILED\n")
        for i, p in enumerate(problems, 1):
            print(f"{i}. {p}\n")
        return 1
    print("VERIFY PASSED - inventory is ready for execute.")
    return 0


def cmd_manifest(args: argparse.Namespace) -> int:
    """Stage 4 helper: render default.xml for the manifest repository.

    Run this only after verify passes; a manifest built from an unverified
    inventory can reference projects that were never pushed.
    """
    from .manifest import generate_manifest

    xml = generate_manifest(
        args.inventory, host=args.host, group=args.group,
        protocol=args.protocol, revision=args.revision,
    )
    Path(args.output).write_text(xml, encoding="utf-8")
    print(f"wrote {args.output}")
    return 0


def cmd_execute(args: argparse.Namespace) -> int:
    """Stage 3: NOT IMPLEMENTED BY DESIGN.

    This is the only stage that writes to GitLab and to disk. Shipping it before a
    human has reviewed inventory.json would invite skipping the review gate, which
    is the one step that prevents silent data loss.

    Instead of running, it prints the contract any implementation must satisfy, and
    exits 2 (distinct from verify's 1, so callers can tell the two apart).
    """
    print(
        "execute is not implemented yet.\n"
        "\n"
        "It must, per stage-3 contract:\n"
        "  - read inventory.json only; make NO fresh judgements at runtime\n"
        "  - create GitLab projects idempotently (GET probe, then POST,\n"
        "    tolerating 400 'has already been taken')\n"
        "  - per project: git init -b main; write .gitattributes for LFS;\n"
        "    git add; git add -f for every 'keep' rule; commit; push\n"
        "  - persist per-project state to state.json to support --resume\n"
        "  - never rm -rf anything inside the SDK\n"
        "  - read the token from $GITLAB_TOKEN, and strip credentials from\n"
        "    .git/config when done\n",
        file=sys.stderr,
    )
    return 2


def main(argv: list[str] | None = None) -> int:
    """Parse arguments and dispatch to the selected stage.

    Each stage is a subcommand rather than a flag, which keeps the four-stage
    pipeline visible in the interface itself: you cannot accidentally run extract
    and execute in one invocation.
    """
    ap = argparse.ArgumentParser(
        prog="sdk-reclaim", description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("extract", help="read-only: SDK tree -> inventory.json")
    p.add_argument("sdk_root")
    p.add_argument("-o", "--output", default="inventory.json")
    p.add_argument("--detector", default="rockchip")
    p.set_defaults(func=cmd_extract)

    p = sub.add_parser("verify", help="read-only: assert the inventory is complete")
    p.add_argument("inventory")
    p.add_argument("--max-file-mb", type=int, default=100,
                   help="flag files above this size when LFS is off")
    p.set_defaults(func=cmd_verify)

    p = sub.add_parser("execute", help="idempotent: create GitLab projects and push")
    p.add_argument("inventory")
    p.add_argument("--resume", action="store_true")
    p.set_defaults(func=cmd_execute)

    p = sub.add_parser("manifest", help="read-only: inventory -> default.xml")
    p.add_argument("inventory")
    p.add_argument("--host", required=True)
    p.add_argument("--group", required=True)
    p.add_argument("--protocol", choices=["ssh", "http"], default="ssh")
    p.add_argument("--revision", default="main")
    p.add_argument("-o", "--output", default="default.xml")
    p.set_defaults(func=cmd_manifest)

    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
