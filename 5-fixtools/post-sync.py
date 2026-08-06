#!/usr/bin/env python3
# post-sync.py -- repo's post-sync hook: replay what git cannot carry.
#
# NOT run by hand. `repo sync` runs this itself, on every sync, once the
# manifest names it:
#
#     <project path=".hooks" name="repo-hooks.git" />
#     <repo-hooks in-project="repo-hooks.git" enabled-list="post-sync" />
#
# That is the whole reason this file exists. A colleague's sync is three
# commands and none of them mention it; without the hook there would be a
# fourth, and a fourth command is one that gets forgotten.
#
# WHAT IT REPLAYS
#   Empty directories, and group/other permission bits. A commit stores a path,
#   its bytes, and one permission bit -- the owner execute bit. Everything else
#   about the filesystem is absent from git by design, so a correct clone of a
#   correct commit still differs from the vendor's packaged tree. This closes
#   that gap. See carry-extras.sh --help for the full account.
#
# WHY IT IS A PYTHON FILE, AND THIN
#   Both are repo's rules, not choices. repo derives the filename from the hook
#   type, so it must be exactly post-sync.py; and it runs the file by
#   exec/compile inside its own interpreter rather than as a subprocess, so it
#   must be Python and must define main(). A bash script cannot be a repo hook.
#
#   The work itself stays in carry-extras.sh, which this only calls. One
#   implementation, one record format, one place to fix a bug -- and the same
#   code path an operator can run by hand to reproduce what a colleague's sync
#   did.
#
# LAYOUT -- all three files live together in repo-hooks.git:
#   post-sync.py     this file
#   carry-extras.sh  the implementation
#   extras.txt       the record, from: carry-extras.sh --record --dir=<original>
#
# ON FAILURE
#   repo constructs this hook with abort_if_user_denies=False, so a failure
#   here prints "Warning: post-sync hook reported failure." and the sync still
#   reports success. That warning is easy to miss, which is why this raises
#   with an explicit instruction rather than returning quietly: the operator
#   who has to act needs to be told what to run.

import os
import subprocess


def main(repo_topdir, **kwargs):
    """Restore empty directories and non-canonical modes across the workspace.

    repo_topdir -- the workspace root, passed by repo.
    **kwargs    -- repo passes sync_duration_seconds and a marker; both unused.
                   Required by repo's hook API so that new arguments can be
                   added later without breaking this file.
    """
    # Relative to this file, not to the working directory. repo chdirs to the
    # workspace root before calling us, so a relative path would resolve
    # against the SDK tree rather than against the hooks project.
    here = os.path.dirname(os.path.abspath(__file__))
    script = os.path.join(here, "carry-extras.sh")
    record = os.path.join(here, "extras.txt")

    # Checked before running, so a missing file names itself. Left to
    # subprocess, the same mistake surfaces as ENOENT on "carry-extras.sh",
    # which does not say which of the two is absent or where it was looked for.
    for path in (script, record):
        if not os.path.isfile(path):
            raise RuntimeError(
                "post-sync hook is incomplete: no %s\n"
                "  Both carry-extras.sh and extras.txt must sit beside "
                "post-sync.py in the hooks project." % path
            )

    # check=False: the returncode is inspected below so that the failure
    # message can say what to do about it. check=True would raise
    # CalledProcessError, which repo wraps in a traceback that buries the
    # script's own output.
    result = subprocess.run(
        [script, "--apply", "--dir", repo_topdir, "--file", record],
        check=False,
    )

    if result.returncode != 0:
        raise RuntimeError(
            "carry-extras.sh failed (exit %d).\n"
            "  The sync itself is fine -- the files are all here. What is\n"
            "  missing is empty directories and some permission bits.\n"
            "  Re-run it by hand to see why:\n"
            "    %s --apply --dir %s --file %s"
            % (result.returncode, script, repo_topdir, record)
        )
