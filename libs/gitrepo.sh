# shellcheck shell=bash
#
# gitrepo.sh -- Local git operations on ONE directory.
#
# Every function here operates on the current working directory and nothing
# else. No function takes or derives a path relative to some larger tree, and
# none of them knows that an SDK exists. That restriction is deliberate: the
# directory layout of the reassembled SDK is expressed in the repo manifest,
# not in repository names, so a per-directory worker has no business knowing
# where it sits.
#
# Includes Git LFS, because LFS is git: `git lfs track` writes
# .gitattributes, and its ordering constraint relative to `git add` only makes
# sense next to the staging code it constrains.
#
# Knows about git. Does not know about GitLab.
#
# Depends on utils.sh for libutils_die() and libutils_require_cmd(); source that first.
#
# Source-only. Not executable.

# The dangling .git symlink is moved here rather than deleted. Its target is
# the only surviving trace of the vendor's original manifest, so destroying it
# would destroy evidence we may want to re-read months from now.
LIBGITREPO_EVIDENCE_FILE=".git.stripped-symlink.bak"

# libgitrepo_check_symlink_dir: die if the target directory is itself a symlink.
#
# $1 -- the directory as the operator named it, before any cd
#
# In this SDK, kernel -> kernel-6.1 and common -> device/rockchip/common.
# Creating a repository for such a location would duplicate the target's
# content on the server, and worse, a later `repo sync` would materialise a
# real directory where a symlink belongs. The correct expression is <linkfile>
# inside the target's own project.
#
# The test is `[ -L ]` on the named path, NOT a comparison of `pwd` against
# `pwd -P`. Those two differ whenever ANY component of the path is a symlink,
# including ones far outside the SDK: an operator working through
# /home/developer/sdk -> /development/src/sdk would see every single directory
# rejected. Only the final component's own nature is our business.
#
# The trailing slash is stripped first, because `[ -L avs/ ]` is false even for
# a symlinked avs -- the trailing slash asks the kernel to resolve the link.
# Tab completion supplies that slash constantly, so without this the check
# would silently pass exactly when it matters.
libgitrepo_check_symlink_dir() {
    local target="${1%/}"

    [ -L "$target" ] || return 0

    libutils_die "$target is a symlink -> $(readlink "$target").
     Do not create a repository here. Express it in the manifest as a
     <linkfile> under the project that owns its target."
}

# libgitrepo_has_evidence: return 0 if the current directory carries a .git
# symlink, dangling or not.
#
# This is the marker that the location was once a repo project. Callers use it
# as a precondition, because a directory with no such marker was either never
# managed or has already been reclaimed.
libgitrepo_has_evidence() {
    [ -L .git ]
}

# libgitrepo_report_evidence: print the .git symlink's target.
#
# Printed before anything is moved, so the target lands in the operator's
# terminal log even if a later stage fails and the run is abandoned.
libgitrepo_report_evidence() {
    libgitrepo_has_evidence || return 0
    libutils_say "evidence: .git -> $(readlink .git)"
}

# libgitrepo_clear_evidence: move the .git symlink aside so `git init` can work.
#
# Not cosmetic: `git init` follows a .git symlink. With a dangling one, git
# would try to create the repository at the nonexistent link target instead of
# here. Moving rather than removing keeps the forensic trail.
#
# Skips silently when the backup already exists, so a re-run does not clobber
# the original evidence with a second copy.
libgitrepo_clear_evidence() {
    libgitrepo_has_evidence || return 0

    if [ -e "$LIBGITREPO_EVIDENCE_FILE" ]; then
        libutils_say "evidence already preserved in $LIBGITREPO_EVIDENCE_FILE; removing symlink"
        rm -f .git
        return 0
    fi

    mv .git "$LIBGITREPO_EVIDENCE_FILE"
    libutils_say "evidence preserved: $LIBGITREPO_EVIDENCE_FILE"
}

# libgitrepo_is_real_repo: return 0 if the current directory holds a git
# repository of its own WITH at least one commit.
#
# No git command appears in this function on purpose. Every git command
# begins by discovering a repository: if ./.git is absent or broken it
# climbs to the parent directory and tries again, and whatever it then
# answers describes the NEAREST ANCESTOR repository, not this directory.
# The previous implementation ran rev-parse behind `[ -d .git ]`, but that
# test does not anchor the git calls that follow it. In a vendor tree whose
# projects nest (rk3588 nests ten projects inside bootable/recovery and
# vendor/rockchip/hardware), a child whose own .git is a stripped skeleton
# still hears "yes" from its parent's fresh repository, is skipped as
# "already a repository", and has the parent's content pushed under its
# name. The filesystem tests below cannot climb, so the mistake cannot
# recur.
#
# They also match the actual vendor state, which the old guard mis-modelled.
# It expected a stripped .git to BE a dangling symlink; the real thing is a
# plain directory whose objects/ and refs/ are symlinks into the removed
# .repo/ tree. `-d` is false for a dangling symlink, so:
#
#   1. skeleton: real .git dir, inner links dangling -- fails `-d .git/objects`;
#   2. a real directory carrying history -- passes, left alone;
#   3. a repository with no commits, left by a run interrupted between
#      `git init` and the first commit -- no branch ref exists yet, fails
#      the last test, gets rebuilt;
#   4. absent -- nothing to protect.
#
# Only state 2 returns 0.
libgitrepo_is_real_repo() {
    [ -d .git ] || return 1          # state 4: no .git at all
    [ -f .git/HEAD ] || return 1     # HEAD must be a real file
    [ -d .git/objects ] || return 1  # state 1: dangling symlink fails -d
    [ -d .git/refs ] || return 1     # state 1: same
    # a commit implies a branch ref: loose under refs/heads (-A sees all
    # entries), or packed into packed-refs after git gc
    [ -n "$(ls -A .git/refs/heads 2>/dev/null)" ] && return 0
    [ -f .git/packed-refs ] && return 0
    return 1                         # state 3: init'd but never committed
}

# libgitrepo_init: create the repository if absent, and ignore our own bookkeeping.
#
# $1 -- branch name for the initial branch
#
# The evidence file is registered in .git/info/exclude rather than .gitignore
# on purpose. info/exclude is local-only and never pushed, so the vendor's tree
# stays byte-identical to what they shipped. Editing their .gitignore would
# create a permanent rebase conflict for one line of our own housekeeping.
libgitrepo_init() {
    local branch="$1"

    if [ -d .git ]; then
        libutils_say "reusing existing .git (this is a re-run)"
    else
        libutils_say "git init (branch $branch)"
        git init
        # git init -b needs git 2.28; checkout -b on an unborn HEAD is the
        # same thing and works on the 2.25 that ubuntu 20.04 ships.
        git checkout -b "$branch"
    fi

    grep -qxF "$LIBGITREPO_EVIDENCE_FILE" .git/info/exclude 2>/dev/null \
        || echo "$LIBGITREPO_EVIDENCE_FILE" >> .git/info/exclude
}

# libgitrepo_check_min_mb: die unless the LFS threshold is a usable size in MB.
#
# $1 -- the threshold as the operator supplied it
#
# Lives here rather than in each caller's option parser because the constraint
# belongs to libgitrepo_find_big, not to any one command line: the value feeds
# $((min_mb - 1)) there, and a non-numeric one would surface as an obscure bash
# arithmetic error naming a variable the operator never typed. Validating at the
# boundary converts that into a complaint about the option itself.
#
# Rejects 0 as well as non-numbers. A 0MB threshold would match every file in
# the tree and push the entire SDK through LFS, which is never what anyone
# means by it.
libgitrepo_check_min_mb() {
    local min_mb="$1"

    case "$min_mb" in
        ''|*[!0-9]*)
            libutils_die "LFS threshold must be a positive integer in MB (got '$min_mb')"
            ;;
        0)
            libutils_die "LFS threshold must be greater than 0"
            ;;
    esac
}

# libgitrepo_require_lfs: die unless Git LFS is installed AND functional.
#
# Callers that process many directories should invoke this once up front rather
# than relying on libgitrepo_setup_lfs to discover the problem. setup_lfs only
# checks when it has actually found a large file, so a batch caller can rebuild
# thirty directories before dying on the thirty-first -- the worst place to
# learn that a dependency is missing.
#
# Two checks, because presence is not usability. `command -v` is satisfied by a
# git-lfs binary whose git filters were never installed or that mismatches the
# git version; `git lfs env` is the cheapest call that actually exercises the
# subsystem and fails in exactly those cases.
#
# Run from a throwaway directory because `git lfs env` is not read-only: outside
# a repository it treats $PWD as the repository root and creates lfs/objects and
# lfs/tmp there. Called as an up-front dependency check, that $PWD is wherever
# the operator launched the script -- so the check would litter their directory
# with an empty lfs/ tree.
libgitrepo_require_lfs() {
    local probe

    libutils_require_cmd git git-lfs

    probe=$(mktemp -d) || libutils_die "cannot create temp dir for the LFS check"

    ( cd "$probe" && git lfs env >/dev/null 2>&1 ) \
        || { rm -rf "$probe"; libutils_die "git-lfs is installed but not functional (check: git lfs env)"; }

    rm -rf "$probe"
}

# libgitrepo_find_big: print files at or above a size threshold, one per line.
#
# $1 -- threshold in MB
#
# find's `-size +N M` means "strictly greater than N MB", so the threshold is
# passed as N-1 to make the comparison inclusive: a 50MB limit must catch a
# file of exactly 50MB.
#
# Prunes .git and the preserved evidence file so neither is ever considered
# for LFS tracking.
libgitrepo_find_big() {
    local min_mb="$1"

    find . -path ./.git -prune \
        -o -name "$LIBGITREPO_EVIDENCE_FILE" -prune \
        -o -type f -size +$((min_mb - 1))M -print 2>/dev/null || true
}

# libgitrepo_setup_lfs: track every file at or above the threshold with Git LFS.
#
# $1 -- threshold in MB
#
# Must run BEFORE libgitrepo_stage. The ordering is not cosmetic: if a large file
# enters history as an ordinary blob, moving it to LFS afterwards requires
# rewriting history. Track first, add second.
#
# `git lfs install --local` confines the filter configuration to this
# repository instead of mutating the operator's ~/.gitconfig -- which matters
# because this script will run across dozens of directories and should leave no
# trace outside them.
#
# Returns 0 when LFS is not needed, so the caller can invoke it
# unconditionally.
libgitrepo_setup_lfs() {
    local min_mb="$1" big count file

    big=$(libgitrepo_find_big "$min_mb")

    if [ -z "$big" ]; then
        libutils_say "LFS: not needed (no file >= ${min_mb}MB)"
        return 0
    fi

    command -v git-lfs >/dev/null \
        || libutils_die "files >= ${min_mb}MB present but git-lfs is not installed"

    count=$(echo "$big" | wc -l)
    libutils_say "LFS: tracking $count file(s) >= ${min_mb}MB"

    # No -q: `git lfs install` has no such flag (it is not git), and passing one
    # makes it print its usage text and exit 127. Under `set -e` that aborts the
    # run; without it, the filters are never installed and every large file is
    # committed as an ordinary blob while the log still says "tracking". Both
    # failures are quiet, so the output is redirected rather than suppressed by a
    # flag that does not exist. Errors are deliberately left on stderr.
    git lfs install --local >/dev/null

    while IFS= read -r file; do
        [ -n "$file" ] || continue
        # Strip find's leading './': .gitattributes patterns are
        # repository-relative and a './' prefix would not match.
        echo "    lfs: ${file#./}"
        git lfs track "${file#./}" >/dev/null
    done <<< "$big"

    # Staged here rather than left to libgitrepo_stage, so .gitattributes is
    # guaranteed to be in the index before any tracked file is added.
    #
    # -f because .gitattributes is OURS, not the vendor's, and some vendor
    # .gitignore files exclude it -- device/rockchip's starts with `.*` and `/*`,
    # which matches it. Without -f, `git add` exits 1 there and `set -e` kills
    # the whole run; and were the failure ignored instead, LFS would be silently
    # inert -- every large file committed as an ordinary blob while the log above
    # still says "tracking".
    git add -f .gitattributes
}

# libgitrepo_stage: stage the working tree, honouring the vendor's .gitignore.
#
# $1 -- space-separated paths to force-add despite .gitignore; may be empty
#
# The default is a plain `git add .`. Whatever their .gitignore excludes stays
# excluded. If the build later fails on a missing file, that failure is the
# signal to come back and force-add it. We do not guess up front, because
# guessing is what makes this class of migration unreviewable.
#
# The force-add list is the single deliberate override, and it exists for one
# specific reason: there is a class of loss that compilation can never reveal.
# When a parent's .gitignore excludes a path because that path used to be a
# nested repo project, the rule was CORRECT under the original multi-repo
# layout and is WRONG once the content is flattened into one repository.
# docs/.gitignore excludes cn/ and en/ for exactly that reason, and those hold
# 322 PDFs. No compile failure would ever reveal their absence, so this is the
# one place where a human decision has to be stated explicitly.
libgitrepo_stage() {
    local force="$1" path

    libutils_say "git add ."
    git add .

    [ -n "$force" ] || return 0

    for path in $force; do
        [ -e "$path" ] || libutils_die "--force-add path does not exist: $path"
        libutils_say "git add -f $path   (overriding .gitignore on purpose)"
        git add -f "$path"
    done
}

# libgitrepo_count_ignored: print how many files the vendor's .gitignore excludes.
#
# Reported so the operator sees the size of what is being dropped before the
# push, not after.
#
# Uses `git ls-files -o -i` rather than `git status --ignored`, because status
# collapses an ignored directory into a single line: a directory holding 322
# files shows up as one entry, which reads as "one file dropped".
#
# --exclude-standard covers .gitignore AND .git/info/exclude, so our own
# evidence file would otherwise be counted as vendor-ignored content. It is
# filtered out to keep the number honest: this figure is meant to answer "how
# much of the vendor's tree am I leaving behind", and our bookkeeping file is
# not part of the vendor's tree.
libgitrepo_count_ignored() {
    git ls-files --others --ignored --exclude-standard 2>/dev/null \
        | grep -vxF "$LIBGITREPO_EVIDENCE_FILE" \
        | wc -l
}

# libgitrepo_commit: create a commit, distinguishing first import from a re-run.
#
# $1 -- commit message for the initial import
# $2 -- commit message for a subsequent update
#
# A re-run with nothing staged must not fail. Being able to retry a directory
# after fixing one thing is the entire reason this tool works per-directory.
libgitrepo_commit() {
    local first_msg="$1" update_msg="$2"

    if ! git rev-parse --verify -q HEAD >/dev/null; then
        git commit -q -m "$first_msg"
        libutils_say "commit: $(git rev-parse --short HEAD) (initial import)"
        return 0
    fi

    if git diff --cached --quiet; then
        libutils_say "commit: nothing new to commit"
        return 0
    fi

    git commit -q -m "$update_msg"
    libutils_say "commit: $(git rev-parse --short HEAD)"
}

# libgitrepo_head: print the full HEAD sha.
#
# A function rather than inline `git rev-parse` at the call sites, so the
# verification step does not have to know whether we are on a branch or
# detached.
libgitrepo_head() {
    git rev-parse HEAD
}
