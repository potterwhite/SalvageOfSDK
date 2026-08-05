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
# Source-only. Not executable.

# The dangling .git symlink is moved here rather than deleted. Its target is
# the only surviving trace of the vendor's original manifest, so destroying it
# would destroy evidence we may want to re-read months from now.
GITREPO_EVIDENCE_FILE=".git.stripped-symlink.bak"

# gitrepo_check_symlink_dir: die if the target directory is itself a symlink.
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
gitrepo_check_symlink_dir() {
    local target="${1%/}"

    [ -L "$target" ] || return 0

    die "$target is a symlink -> $(readlink "$target").
     Do not create a repository here. Express it in the manifest as a
     <linkfile> under the project that owns its target."
}

# gitrepo_has_evidence: return 0 if the current directory carries a .git
# symlink, dangling or not.
#
# This is the marker that the location was once a repo project. Callers use it
# as a precondition, because a directory with no such marker was either never
# managed or has already been reclaimed.
gitrepo_has_evidence() {
    [ -L .git ]
}

# gitrepo_report_evidence: print the .git symlink's target.
#
# Printed before anything is moved, so the target lands in the operator's
# terminal log even if a later stage fails and the run is abandoned.
gitrepo_report_evidence() {
    gitrepo_has_evidence || return 0
    say "evidence: .git -> $(readlink .git)"
}

# gitrepo_clear_evidence: move the .git symlink aside so `git init` can work.
#
# Not cosmetic: `git init` follows a .git symlink. With a dangling one, git
# would try to create the repository at the nonexistent link target instead of
# here. Moving rather than removing keeps the forensic trail.
#
# Skips silently when the backup already exists, so a re-run does not clobber
# the original evidence with a second copy.
gitrepo_clear_evidence() {
    gitrepo_has_evidence || return 0

    if [ -e "$GITREPO_EVIDENCE_FILE" ]; then
        say "evidence already preserved in $GITREPO_EVIDENCE_FILE; removing symlink"
        rm -f .git
        return 0
    fi

    mv .git "$GITREPO_EVIDENCE_FILE"
    say "evidence preserved: $GITREPO_EVIDENCE_FILE"
}

# gitrepo_init: create the repository if absent, and ignore our own bookkeeping.
#
# $1 -- branch name for the initial branch
#
# The evidence file is registered in .git/info/exclude rather than .gitignore
# on purpose. info/exclude is local-only and never pushed, so the vendor's tree
# stays byte-identical to what they shipped. Editing their .gitignore would
# create a permanent rebase conflict for one line of our own housekeeping.
gitrepo_init() {
    local branch="$1"

    if [ -d .git ]; then
        say "reusing existing .git (this is a re-run)"
    else
        say "git init -b $branch"
        git init -q -b "$branch"
    fi

    grep -qxF "$GITREPO_EVIDENCE_FILE" .git/info/exclude 2>/dev/null \
        || echo "$GITREPO_EVIDENCE_FILE" >> .git/info/exclude
}

# gitrepo_find_big: print files at or above a size threshold, one per line.
#
# $1 -- threshold in MB
#
# find's `-size +N M` means "strictly greater than N MB", so the threshold is
# passed as N-1 to make the comparison inclusive: a 50MB limit must catch a
# file of exactly 50MB.
#
# Prunes .git and the preserved evidence file so neither is ever considered
# for LFS tracking.
gitrepo_find_big() {
    local min_mb="$1"

    find . -path ./.git -prune \
        -o -name "$GITREPO_EVIDENCE_FILE" -prune \
        -o -type f -size +$((min_mb - 1))M -print 2>/dev/null || true
}

# gitrepo_setup_lfs: track every file at or above the threshold with Git LFS.
#
# $1 -- threshold in MB
#
# Must run BEFORE gitrepo_stage. The ordering is not cosmetic: if a large file
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
gitrepo_setup_lfs() {
    local min_mb="$1" big count file

    big=$(gitrepo_find_big "$min_mb")

    if [ -z "$big" ]; then
        say "LFS: not needed (no file >= ${min_mb}MB)"
        return 0
    fi

    command -v git-lfs >/dev/null \
        || die "files >= ${min_mb}MB present but git-lfs is not installed"

    count=$(echo "$big" | wc -l)
    say "LFS: tracking $count file(s) >= ${min_mb}MB"
    git lfs install --local -q

    while IFS= read -r file; do
        [ -n "$file" ] || continue
        # Strip find's leading './': .gitattributes patterns are
        # repository-relative and a './' prefix would not match.
        echo "    lfs: ${file#./}"
        git lfs track "${file#./}" >/dev/null
    done <<< "$big"

    # Staged here rather than left to gitrepo_stage, so .gitattributes is
    # guaranteed to be in the index before any tracked file is added.
    git add .gitattributes
}

# gitrepo_stage: stage the working tree, honouring the vendor's .gitignore.
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
gitrepo_stage() {
    local force="$1" path

    say "git add ."
    git add .

    [ -n "$force" ] || return 0

    for path in $force; do
        [ -e "$path" ] || die "--force-add path does not exist: $path"
        say "git add -f $path   (overriding .gitignore on purpose)"
        git add -f "$path"
    done
}

# gitrepo_count_ignored: print how many files the vendor's .gitignore excludes.
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
gitrepo_count_ignored() {
    git ls-files --others --ignored --exclude-standard 2>/dev/null \
        | grep -vxF "$GITREPO_EVIDENCE_FILE" \
        | wc -l
}

# gitrepo_commit: create a commit, distinguishing first import from a re-run.
#
# $1 -- commit message for the initial import
# $2 -- commit message for a subsequent update
#
# A re-run with nothing staged must not fail. Being able to retry a directory
# after fixing one thing is the entire reason this tool works per-directory.
gitrepo_commit() {
    local first_msg="$1" update_msg="$2"

    if ! git rev-parse --verify -q HEAD >/dev/null; then
        git commit -q -m "$first_msg"
        say "commit: $(git rev-parse --short HEAD) (initial import)"
        return 0
    fi

    if git diff --cached --quiet; then
        say "commit: nothing new to commit"
        return 0
    fi

    git commit -q -m "$update_msg"
    say "commit: $(git rev-parse --short HEAD)"
}

# gitrepo_head: print the full HEAD sha.
#
# A function rather than inline `git rev-parse` at the call sites, so the
# verification step does not have to know whether we are on a branch or
# detached.
gitrepo_head() {
    git rev-parse HEAD
}
