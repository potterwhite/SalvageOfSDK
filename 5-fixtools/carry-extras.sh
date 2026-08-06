#!/bin/bash
set -ex

# carry-extras.sh -- Carry filesystem state across a rebuild that git drops.
#
# One script, two directions, because they are one contract. --record reads the
# original tree and writes a record file; --apply reads that record file and
# restores what it describes into a synced workspace. Splitting them into two
# scripts would let the format drift between the writer and the reader, and the
# format is the only thing either of them is about.
#
# What it carries, and why nothing else can:
#
#   Empty directories. Git has no object type for a directory with no entries.
#   One in the vendor tree is absent from every clone of that tree, on every
#   machine, forever. This SDK has 39.
#
#   Group and other permission bits. A commit stores one permission bit, the
#   owner execute bit. The rest come from the umask of whoever ran the sync.
#   This SDK was packaged with a mixture -- 188000 entries at 755/644 and 155 at
#   775/664 -- so no single umask reproduces it and the instruction "set umask
#   022 before syncing" is not merely fragile, it is insufficient.
#
# Neither is a bug in 2-rebuild.sh, and neither can be fixed by committing more
# carefully. They are limits of the format, and this is the compensating step.
#
# ============================================================================
# 1_0  Libraries
# ============================================================================

# func_1_0_load_libs: source the shared libraries.
#
# Two layouts, because this script runs from two places. In the toolkit it sits
# in 5-fixtools/ with libs/ beside that, one level up. Shipped as a repo hook it
# sits in repo-hooks.git next to post-sync.py, where the three files are flat
# and libs/ is a sibling rather than an uncle.
#
# The sibling is tried first: a hooks project is assembled deliberately, so a
# libs/ found there is the one meant to be used. Guessing the other way round
# would have a stray directory in the hooks project silently lose to the
# toolkit's copy, and a version skew between them is exactly the bug that
# produces a correct-looking run with the wrong result.
func_1_0_load_libs(){
    local here libs
    here="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

    if [ -f "$here/libs/utils.sh" ]; then
        libs="$here/libs"                 # hook layout: libs/ beside this script
    else
        libs="$(dirname "$here")/libs"    # toolkit layout: 5-fixtools/../libs
    fi

    [ -f "$libs/utils.sh" ] || {
        echo "ERROR: cannot find the libs/ directory (looked in $here/libs and $(dirname "$here")/libs)" >&2
        exit 1
    }

    . "$libs/utils.sh"   # first: everything below calls libutils_die
    . "$libs/args.sh"
    . "$libs/extras.sh"

    # Only --repo-hook-dir needs it, and it is deliberately absent from the hook
    # bundle: gitlab.sh handles access tokens, and the bundle is cloned by
    # everyone who syncs the SDK. Sourcing it unconditionally would make the
    # hook fail at runtime on a file it has no use for.
    LIBS_DIR="$libs"
}

# func_1_0b_load_gitlab: source the GitLab library, or explain its absence.
#
# Called only in bundle mode, after the mode is known.
func_1_0b_load_gitlab(){
    [ -f "$LIBS_DIR/gitlab.sh" ] || \
        libutils_die "cannot find $LIBS_DIR/gitlab.sh, which --repo-hook-dir needs.
     Run this from the toolkit checkout, not from a hook bundle -- the bundle
     deliberately omits that library."

    . "$LIBS_DIR/gitlab.sh"
}

# ============================================================================
# 1_1  Help
# ============================================================================

# func_1_1_show_help: print the usage text.
#
# Unquoted <<EOF so ${0##*/} expands to the real script name. Consequence:
# nothing in the body may carry a bare '$' or it silently expands to empty.
func_1_1_show_help(){
    cat <<EOF
Usage: ${0##*/} --repo-hook-dir=DIR --baseline-dir=ORIGINAL \\
           --gitlab-url=URL --gitlab-group=G \\
           --git-user-name=NAME --git-user-email=EMAIL [--push --gitlab-token=PAT]
       ${0##*/} --record --dir=ORIGINAL > extras.txt
       ${0##*/} --apply  --dir=WORKSPACE --file=extras.txt
       ${0##*/} -h | --help

Carry the two things a git commit cannot: empty directories, and the group and
other permission bits.

WHY THIS EXISTS
  A commit stores a path, its bytes, and one permission bit -- the owner
  execute bit. So a tree cloned from a perfectly correct commit still differs
  from the vendor's packaged tree in two ways no rebuild can fix:

    An empty directory cannot be committed, so it cannot be checked out. This
    SDK has 39, mostly toolchain directories under prebuilts/.

    Group and other bits are supplied by the umask of the shell that ran the
    sync. This SDK was packaged with a mixture: most entries at 755/644, and
    155 at 775/664 under external/mpp/build, kernel-6.1/tools/build and
    device/rockchip/common/scripts. No single umask produces both, so telling
    colleagues to set umask 022 cannot close the gap -- it only moves which
    155 entries are wrong.

  --apply handles that by normalising the whole tree to what umask 022 would
  have produced, and then restoring the recorded exceptions on top. The result
  does not depend on the umask of whoever ran the sync.

RECORD
  Run once, against the original vendor tree:

    ${0##*/} --record --dir=/path/to/original > extras.txt

  Reads only. Safe against a read-only tree, which is the point -- the
  authoritative source for this record is the pristine original.

  Regenerate it rather than editing it. The file is sorted so that an unchanged
  tree produces byte-identical output, which makes its diff worth reviewing.

APPLY
  Normally nobody runs this: 'repo sync' does, through the hook. By hand, to
  check a workspace or to reproduce what a sync did:

    ${0##*/} --apply --dir=. --file=extras.txt

  Idempotent. Running it twice does the same thing as running it once, which is
  what lets the hook run it on every sync without a guard.

  Start with --dry-run. It counts what would change and changes nothing.

REPO-HOOK-DIR -- build the hook repository
  One command that does everything the server side needs:

    ${0##*/} --repo-hook-dir=~/repo-hooks --baseline-dir=/path/to/original \\
        --gitlab-url=http://gitlab.example.com --gitlab-group=RK3576 \\
        --git-user-name="Your Name" --git-user-email=you@example.com \\
        --gitlab-token=PAT --push

  It records the baseline, assembles the four files repo needs, makes them a git
  repository, creates the GitLab project, pushes it, and prints the two lines to
  paste into default.xml. Without --push it does all of that except the last
  two, so you can look before anything leaves the machine.

  The four files, and why they sit together: repo finds a hook by joining the
  hooks project's checkout path with the hook name plus ".py". So post-sync.py
  must be at the root of that project, and what it calls must be beside it.

    post-sync.py     the entry point; the name is repo's rule, not a choice
    carry-extras.sh  this script, which post-sync.py calls
    libs/            the three libraries it sources
    extras.txt       the record, from --baseline-dir

  It must be its own repository -- repo's documentation is explicit that the
  hooks project is a separate repo referenced by name, not a subdirectory.

  Re-run it to refresh the bundle after the toolkit or the baseline changes. It
  commits over the previous state rather than starting a new history.

AFTERWARDS
  Paste the two printed lines into default.xml, then publish the manifest.
  Colleagues sync with:

    repo init -u <manifest url> -b main
    repo sync -j8 --verify
    repo forall -c 'git lfs pull' -j4

  Still three commands. The --verify is what stops repo asking each of them to
  approve the hook the first time; without it the first sync waits on a
  (yes/always/NO) prompt, and answering NO silently skips the hook.

WHAT IT DOES NOT DO
  Ownership. uid and gid belong to the machine that unpacked the vendor
  archive, not to the SDK, and restoring them needs root. A colleague's tree
  owned by that colleague is correct.

  Symlink modes. A symlink's own mode is unused on Linux, and chmod without -h
  would change its target instead.

  Anything inside .git or .repo. Git writes loose objects read-only
  deliberately; making them writable invites it to rewrite an object it
  assumes is immutable.

  Files a .gitignore excluded from the rebuild. Their recorded modes cannot be
  restored, because the files were never committed. --apply counts them and
  says so. That count is a useful independent measure of how much content the
  rebuild is still missing.

Pick one of three:
  --repo-hook-dir=DIR    Build the hook repository in DIR. Created if absent.
  --record               Read a tree, write a record to stdout. Changes nothing.
  --apply                Read a record, restore it into a tree.

Required with --repo-hook-dir:
  --baseline-dir=DIR     The original vendor tree to record from. Read only, so
                         it can be the unwritable pristine copy -- which is the
                         one it should be.
  --gitlab-url=URL       e.g. --gitlab-url=http://gitlab.example.com
  --gitlab-group=GROUP   The group to create the project in, e.g. RK3576
  --git-user-name=NAME   Value for git config user.name
  --git-user-email=EMAIL Value for git config user.email

Required with --record and --apply:
  --dir=DIR              With --record, the original tree to read.
                         With --apply, the workspace to change.

Required with --apply:
  --file=PATH            The record file to read.

Options:
  --push                 Create the GitLab project and push. Without it nothing
                         leaves this machine: the bundle is built and committed
                         locally and the manifest lines are printed, so you can
                         rehearse the whole thing and push by hand afterwards.
  --gitlab-token=PAT     Required by --push. Needs api scope. Never written to
                         disk: it is spliced into the push URL, and scrubbed
                         from .git/config by a trap that fires on Ctrl-C too.
  --project-name=NAME    Name for the GitLab project, which is also what the
                         manifest lines reference. Give it without .git; both
                         the manifest lines and the push URL append that
                         themselves. default repo-hooks
  --branch=NAME          Branch to create and push. default main
                         Must match the manifest's default revision, or
                         'repo sync' finds no such branch.
  --visibility=V         private, internal or public. default private
  --dry-run              With --apply: count what would change, change nothing.
  --no-normalize         With --apply: restore the recorded exceptions but skip
                         the tree-wide normalisation. Only useful for
                         re-checking a tree that is already normalised, and it
                         does not save much -- normalisation is idempotent.
  -h, --help             Print this text and exit. Changes nothing.

  Underscores and hyphens are interchangeable. Both --key=value and --key value
  are accepted.

Exit status:
  0  built, recorded, or applied
  1  refused, or something failed. --apply validates the whole record file
     before it changes anything, so a malformed record changes nothing. With
     --repo-hook-dir the manifest lines print last, so seeing them means every
     step before them succeeded.
EOF
}

# ============================================================================
# 1_2  Option vocabulary
# ============================================================================

func_1_2_check_options(){
    OPTION_NAMES="dir file record apply repo-hook-dir baseline-dir \
gitlab-url gitlab-group gitlab-token git-user-name git-user-email \
project-name branch visibility push dry-run no-normalize help"

    libargs_check_known "$OPTION_NAMES" "$@"
}

# ============================================================================
# 1_3  Direction
# ============================================================================

# func_1_3_init_mode: decide which of the three things this run does.
#
# $@ -- the caller's raw arguments
#
# There is no default. Two of the three write something, and guessing wrong in a
# writing direction changes a tree the operator meant only to look at. Two words
# of typing is the right price for that.
func_1_3_init_mode(){
    local record=no apply=no bundle=no chosen=0

    libargs_is_true record "$@" && record=yes
    libargs_is_true apply "$@" && apply=yes
    libargs_has repo-hook-dir "$@" && bundle=yes

    [ "$record" = yes ] && chosen=$((chosen + 1))
    [ "$apply" = yes ] && chosen=$((chosen + 1))
    [ "$bundle" = yes ] && chosen=$((chosen + 1))

    if [ "$chosen" -gt 1 ]; then
        libutils_die "give only one of --repo-hook-dir, --record, --apply (try --help)"
    fi
    if [ "$chosen" -eq 0 ]; then
        libutils_die "give one of --repo-hook-dir, --record, --apply (try --help)"
    fi

    MODE=record
    [ "$apply" = yes ] && MODE=apply
    [ "$bundle" = yes ] && MODE=bundle

    if libargs_is_true dry-run "$@"; then
        DRY_RUN=yes
        [ "$MODE" = apply ] || \
            libutils_die "--dry-run only means something with --apply; use --repo-hook-dir without --push to rehearse a bundle"
    else
        DRY_RUN=no
    fi

    if libargs_is_true no-normalize "$@"; then
        NORMALIZE=no
        [ "$MODE" = apply ] || libutils_die "--no-normalize only means something with --apply"
    else
        NORMALIZE=yes
    fi
}

# ============================================================================
# 1_4  The tree
# ============================================================================

# func_1_4_init_dir: resolve the tree this run operates on.
#
# $@ -- the caller's raw arguments
#
# Write access is required for --apply and deliberately not for --record. The
# authoritative tree to record from is the pristine original, which is kept
# unwritable precisely so that nothing can modify it; demanding -w would make
# this tool refuse to read the one tree it most needs to read.
#
# --repo-hook-dir has its own two directories and does not use this one.
func_1_4_init_dir(){
    local dir

    if [ "$MODE" = bundle ]; then
        return 0
    fi

    libargs_has dir "$@" || libutils_die "no --dir given (try --help)"
    dir=$(libargs_get dir "" "$@")
    [ -n "$dir" ] || libutils_die "--dir is empty"

    [ -d "$dir" ] || libutils_die "not a directory: $dir"
    [ -r "$dir" ] || libutils_die "directory is not readable: $dir"

    DIR=$(cd "$dir" && pwd -P)

    if [ "$MODE" = apply ] && [ "$DRY_RUN" = no ]; then
        [ -w "$DIR" ] || libutils_die "directory is not writable: $DIR"
    fi
}

# ============================================================================
# 1_5  The record file
# ============================================================================

# func_1_5_init_file: resolve the record file.
#
# $@ -- the caller's raw arguments
#
# Only --apply needs one. --record writes to stdout, so that its output can be
# redirected, piped or diffed against an existing record without a temporary
# file -- and so that it cannot overwrite a record by accident.
func_1_5_init_file(){
    if [ "$MODE" != apply ]; then
        return 0
    fi

    libargs_has file "$@" || libutils_die "--apply needs --file=PATH (the record to read)"
    FILE=$(libargs_get file "" "$@")
    [ -n "$FILE" ] || libutils_die "--file is empty"
    [ -f "$FILE" ] || libutils_die "no such record file: $FILE"
}

# ============================================================================
# 1_6  The bundle's configuration
# ============================================================================

# func_1_6_init_bundle: read the options --repo-hook-dir needs.
#
# $@ -- the caller's raw arguments
#
# All of it is read and checked before anything is built, including the token,
# which is not needed until the last step. By then the repository exists and the
# operator would have to re-run anyway; this is the last moment where failing
# costs nothing.
#
# The URL and group are required even without --push, because they are what the
# printed manifest lines and the remote are built from. A rehearsal that prints
# lines with an empty fetch base is a rehearsal of the wrong thing.
func_1_6_init_bundle(){
    local dir baseline

    if [ "$MODE" != bundle ]; then
        return 0
    fi

    dir=$(libargs_get repo-hook-dir "" "$@")
    [ -n "$dir" ] || libutils_die "--repo-hook-dir is empty"
    mkdir -p "$dir" || libutils_die "cannot create --repo-hook-dir: $dir"
    HOOK_DIR=$(cd "$dir" && pwd -P)

    func_1_6a_check_hook_dir

    libargs_has baseline-dir "$@" || \
        libutils_die "--repo-hook-dir needs --baseline-dir (the original tree to record from)"
    baseline=$(libargs_get baseline-dir "" "$@")
    [ -n "$baseline" ] || libutils_die "--baseline-dir is empty"
    [ -d "$baseline" ] || libutils_die "--baseline-dir is not a directory: $baseline"
    [ -r "$baseline" ] || libutils_die "--baseline-dir is not readable: $baseline"
    BASELINE=$(cd "$baseline" && pwd -P)

    # The bundle would otherwise be recorded from inside the tree it describes,
    # and then committed into it.
    case "$HOOK_DIR/" in
        "$BASELINE"/*) libutils_die "--repo-hook-dir is inside --baseline-dir; put the hook repository somewhere else" ;;
    esac

    GITLAB_URL=$(libargs_get gitlab-url "" "$@")
    [ -n "$GITLAB_URL" ] || \
        libutils_die "missing required option: --gitlab-url (e.g. --gitlab-url=http://gitlab.example.com)"

    GITLAB_GROUP=$(libargs_get gitlab-group "" "$@")
    [ -n "$GITLAB_GROUP" ] || \
        libutils_die "missing required option: --gitlab-group (the GitLab group to push into)"

    GIT_USER_NAME=$(libargs_get git-user-name "" "$@")
    [ -n "$GIT_USER_NAME" ] || \
        libutils_die "missing required option: --git-user-name (value for git config user.name)"

    GIT_USER_EMAIL=$(libargs_get git-user-email "" "$@")
    [ -n "$GIT_USER_EMAIL" ] || \
        libutils_die "missing required option: --git-user-email (value for git config user.email)"

    PROJECT_NAME=$(libargs_get project-name "repo-hooks" "$@")
    [ -n "$PROJECT_NAME" ] || libutils_die "--project-name was given an empty value"

    BRANCH=$(libargs_get branch "main" "$@")
    [ -n "$BRANCH" ] || libutils_die "--branch was given an empty value"

    VISIBILITY=$(libargs_get visibility "private" "$@")
    case "$VISIBILITY" in
        private|internal|public) ;;
        *) libutils_die "--visibility must be private, internal or public (got '$VISIBILITY')" ;;
    esac

    GITLAB_TOKEN=$(libargs_get gitlab-token "" "$@")

    if libargs_is_true push "$@"; then
        DO_PUSH=yes
        [ -n "$GITLAB_TOKEN" ] || libutils_die "--push needs --gitlab-token (api scope)"
    else
        DO_PUSH=no
    fi

    # This script and the libraries it copies are read from the toolkit it was
    # run out of, not from a configured path: a bundle assembled from a
    # different checkout than the one being invoked is the kind of version skew
    # that produces a correct-looking run with a stale result.
    TOOLKIT=$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")
    [ -f "$TOOLKIT/5-fixtools/post-sync.py" ] || \
        libutils_die "cannot find post-sync.py beside this script (looked in $TOOLKIT/5-fixtools)"
}

# ============================================================================
# 1_6a  Is that directory ours to write in?
# ============================================================================

# func_1_6a_check_hook_dir: refuse a directory that is not empty and not a
# bundle this tool built.
#
# Empty is fine -- a first run. A previous bundle is fine -- a re-run, which is
# how the record gets refreshed. Anything else is refused, because the next
# steps are `git init` and `git add` in that directory, and the result is pushed
# to a repository every colleague clones. A --repo-hook-dir typed one character
# wrong would publish whatever happened to be there.
#
# Recognition is by post-sync.py and extras.txt together. Either alone could be
# a coincidence in someone's working directory; both, at the top of the same
# directory, is this tool's own output.
#
# Refused rather than prompted, so the script can be called from another script:
# a prompt in a pipeline reads EOF and would take that as consent or as refusal,
# and neither is a decision anybody made.
func_1_6a_check_hook_dir(){
    local n

    # -A so that the count ignores . and .. but does include dotfiles: a
    # directory holding only .config is not empty in any sense that matters.
    n=$(ls -A "$HOOK_DIR" 2>/dev/null | wc -l | tr -d ' ')

    if [ "$n" -eq 0 ]; then
        return 0
    fi

    if [ -f "$HOOK_DIR/post-sync.py" ] && [ -f "$HOOK_DIR/extras.txt" ]; then
        libutils_say "reusing the existing hook repository in $HOOK_DIR"
        return 0
    fi

    libutils_die "$HOOK_DIR is not empty, and is not a hook repository this tool built
     It holds $n entr$([ "$n" = 1 ] && echo y || echo ies), and the next steps here are 'git init' and
     'git add' -- whose result gets pushed to a repository every colleague
     clones. Refusing to do that to a directory whose contents are not ours.
     Point --repo-hook-dir somewhere else, or empty it yourself first."
}

# ============================================================================
# 1_7  Dependencies
# ============================================================================

func_1_7_check_deps(){
    libutils_require_cmd find awk sort chmod mkdir

    if [ "$MODE" = bundle ]; then
        libutils_require_cmd git cp
        [ "$DO_PUSH" = no ] || libutils_require_cmd curl
    fi
}

# ============================================================================
# 2_0  Record
# ============================================================================

# func_2_0_record: write the record for the tree to stdout.
#
# The counts go to stderr afterwards, so they are visible when the operator
# redirects stdout to a file -- which is the only way this mode is meant to be
# used. Counting by re-reading the written file rather than by tallying during
# the walk keeps one source of truth: what the file says is what is reported.
func_2_0_record(){
    local tmp dirs modes

    tmp=$(mktemp) || libutils_die "cannot create a temporary file"
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" EXIT

    libutils_say "reading $DIR ..."
    libextras_record "$DIR" "$DIR" > "$tmp"

    cat "$tmp"

    dirs=$(libextras_count "$tmp" dir)
    modes=$(libextras_count "$tmp" mode)

    libutils_say ""
    libutils_say "recorded $dirs empty director$([ "$dirs" = 1 ] && echo y || echo ies) and $modes non-canonical mode(s)"
    libutils_say ""
    libutils_say "To build the hook repository in one step instead, use --repo-hook-dir."
}

# ============================================================================
# 3_0  Apply
# ============================================================================

# func_3_0_apply: restore the record into the tree.
#
# Order: validate, then normalise, then directories, then modes.
#
# Validation first, so a malformed record changes nothing at all rather than
# half a tree. Normalisation before the exceptions, because it would otherwise
# overwrite them -- it is a blanket chmod and does not know which entries the
# record singles out. Directories before modes, because a recorded empty
# directory may also carry a recorded mode and has to exist to be chmod'd.
func_3_0_apply(){
    local dirs_out modes_out created existed occupied applied missing

    libutils_say "validating $FILE ..."
    libextras_validate "$FILE"

    if [ "$DRY_RUN" = yes ]; then
        libutils_say "DRY RUN -- nothing will be changed"
    fi

    if [ "$NORMALIZE" = yes ]; then
        if [ "$DRY_RUN" = yes ]; then
            libutils_say "would normalise every entry under $DIR to 755 / 644 (umask 022 equivalent)"
        else
            libutils_say "normalising modes under $DIR to 755 / 644 ..."
            libextras_normalize "$DIR"
        fi
    else
        libutils_say "skipping normalisation (--no-normalize)"
    fi

    libutils_say "restoring empty directories ..."
    dirs_out=$(libextras_apply_dirs "$FILE" "$DIR" "$DRY_RUN")
    read -r created existed occupied <<EOF
$dirs_out
EOF

    libutils_say "restoring recorded modes ..."
    modes_out=$(libextras_apply_modes "$FILE" "$DIR" "$DRY_RUN")
    read -r applied missing <<EOF
$modes_out
EOF

    func_3_1_report "$created" "$existed" "$occupied" "$applied" "$missing"
}

# ============================================================================
# 3_1  What happened
# ============================================================================

# func_3_1_report: summarise the run.
#
# $1 -- directories created
# $2 -- directories already present
# $3 -- directories that could not be created
# $4 -- modes applied
# $5 -- modes whose path does not exist
#
# The missing-modes count is called out rather than buried, because it measures
# something no other step reports: every path in it is content the original
# tree has and the rebuild does not. Zero is the goal, and a non-zero number is
# a list of things still to fix in the manifest -- not a fault in this run.
func_3_1_report(){
    local created="$1" existed="$2" occupied="$3" applied="$4" missing="$5"
    local verb="restored"

    [ "$DRY_RUN" = no ] || verb="would restore"

    libutils_say ""
    libutils_say "SUMMARY"
    libutils_say "  empty directories: $verb $created, already present $existed"
    libutils_say "  recorded modes:    $verb $applied"

    if [ "$occupied" -gt 0 ]; then
        libutils_say ""
        libutils_warn "$occupied recorded empty director$([ "$occupied" = 1 ] && echo y || echo ies) exist(s) with content or as another type."
        libutils_warn "Left alone. The two trees genuinely disagree about what belongs there;"
        libutils_warn "that is for you to look at, not for this tool to resolve by deleting."
    fi

    if [ "$missing" -gt 0 ]; then
        libutils_say ""
        libutils_warn "$missing recorded mode(s) name a path that does not exist here."
        libutils_warn "Those are files the original tree has and this one does not -- almost"
        libutils_warn "always excluded from the rebuild by a project's own .gitignore."
        libutils_warn "Not a failure of this run, and worth tracking down: the count is an"
        libutils_warn "independent measure of content the rebuild is still missing."
    fi

    if [ "$DRY_RUN" = yes ]; then
        libutils_say ""
        libutils_say "Nothing was changed. Re-run without --dry-run to apply."
    fi
}

# ============================================================================
# 4_0  Build the hook repository
# ============================================================================

# func_4_0_bundle: assemble the four files, commit them, and push if asked.
#
# The order is the same as adopt-dir.sh's, and for the same reason: everything
# that can be refused is refused before anything is created, and the manifest
# lines print last, so seeing them means every step before them succeeded.
#
# Only our own four paths are staged, never `git add -A`. The bundle is cloned by
# everyone who syncs the SDK, so staging the whole directory would publish
# anything else that happened to be in it. Naming the paths also means a stale
# library removed from the bundle is staged as a deletion, because `git add` on a
# path that no longer exists records the removal.
func_4_0_bundle(){
    local dirs modes

    libutils_say "recording $BASELINE ..."
    libextras_bundle_write "$TOOLKIT" "$HOOK_DIR" "$BASELINE"

    dirs=$(libextras_count "$HOOK_DIR/extras.txt" dir)
    modes=$(libextras_count "$HOOK_DIR/extras.txt" mode)
    libutils_say "recorded $dirs empty director$([ "$dirs" = 1 ] && echo y || echo ies) and $modes non-canonical mode(s)"

    cd "$HOOK_DIR"

    if [ ! -d .git ]; then
        libutils_say "creating a git repository in $HOOK_DIR"
        git init -q -b "$BRANCH"
    fi

    git config user.name "$GIT_USER_NAME"
    git config user.email "$GIT_USER_EMAIL"

    git add post-sync.py carry-extras.sh extras.txt libs

    # Nothing to commit is the expected outcome of re-running against an
    # unchanged toolkit and an unchanged baseline. It is not a failure, and
    # under `set -e` an unguarded git commit would end the run right here.
    if git diff --cached --quiet; then
        libutils_say "no changes to commit (bundle already current)"
    else
        git commit -q -m "Update repo post-sync hook bundle"
        libutils_say "committed $(git rev-parse --short HEAD)"
    fi

    if [ "$DO_PUSH" = yes ]; then
        libgitlab_ensure_project "$GITLAB_URL" "$GITLAB_GROUP" "$PROJECT_NAME" \
            "$GITLAB_TOKEN" "$VISIBILITY"

        libgitlab_push "$GITLAB_URL" "$GITLAB_GROUP" "$PROJECT_NAME" \
            "$GITLAB_TOKEN" "$BRANCH"

        libgitlab_verify_push "$GITLAB_URL" "$GITLAB_GROUP" "$PROJECT_NAME" \
            "$GITLAB_TOKEN" "$BRANCH" "$(git rev-parse HEAD)"
    else
        libgitlab_setup_remote "$GITLAB_URL" "$GITLAB_GROUP" "$PROJECT_NAME"
    fi

    libutils_say "remote origin: $(git remote get-url origin)"
}

# ============================================================================
# 4_1  What to do next
# ============================================================================

# func_4_1_bundle_next_steps: print the manual half, with the manifest lines
# in the middle of the step that uses them.
#
# The lines go to stdout and everything else to stderr, so they can still be
# captured on their own:
#     carry-extras.sh --repo-hook-dir=... 2>/dev/null
#
# That split is why this is three writes rather than one heredoc: a heredoc is
# a single stream, so nothing else can print into the middle of it.
func_4_1_bundle_next_steps(){
    cat >&2 <<EOF

============================================================================
NEXT STEPS -- none of this happened automatically
============================================================================

STEP 1. Paste these two lines into default.xml, before </manifest>:
EOF

    echo "" >&2
    libextras_manifest_lines "$PROJECT_NAME"
    echo "" >&2

    cat >&2 <<EOF
  (Those two lines are this script's only stdout. Everything else is stderr,
  so '2>/dev/null' gives you just them.)

  The first is an ordinary project: it tells repo to check the hook repository
  out at .hooks/. The second says that project holds hooks, and that
  post-sync is enabled. Both are self-closing and take no children.

STEP 2. Commit and push the manifest, or run 3-publish-manifest.sh.

STEP 3. Tell colleagues to sync with --verify:

    repo init -u <manifest url> -b ${BRANCH}
    repo sync -j8 --verify
    repo forall -c 'git lfs pull' -j4

  Still three commands. Without --verify the first sync stops on a
  (yes/always/NO) prompt asking them to approve the hook, and answering NO
  skips it silently -- the sync still reports success.

STEP 4 (optional, and for you -- not for colleagues). Sync a scratch
workspace yourself once, after STEP 2, and check two paths:

    ls -d <scratch>/.hooks
    ls -d <scratch>/app/ipcweb-backend/thirdparty/googletest

  The first shows the hook repository arrived. The second is one of the empty
  directories only the hook creates, so it shows the hook actually ran.

  Worth doing once because repo hides both ways this can go wrong: a failing
  hook only prints 'Warning: post-sync hook reported failure', and a colleague
  who forgets --verify has the hook skipped silently. Either way the sync still
  says it succeeded. Those two paths are the only honest signal.
EOF

    if [ "$DO_PUSH" != yes ]; then
        cat >&2 <<EOF

NOT PUSHED (no --push). The repository is built and committed locally and the
remote is set, so you can push it yourself without retyping the server details:

    cd ${HOOK_DIR} && git push -u origin ${BRANCH}

That needs the GitLab project to exist already. If it does not, re-run this
with --push --gitlab-token=PAT, which creates it first.
EOF
    fi
}

# ============================================================================
# main
# ============================================================================

# main: the mode is decided before the directories are resolved, because it is
# what decides which directories are required and whether write access is.
main(){
    func_1_0_load_libs

    if libargs_is_true help "$@"; then
        func_1_1_show_help
        exit 0
    fi
    # Separately, because libargs_key strips only a leading '--': a single-dash
    # -h never matches an option name. Same shape as the other entry scripts.
    case "${1:-}" in
        -h)
            func_1_1_show_help
            exit 0
            ;;
    esac

    func_1_2_check_options "$@"
    func_1_3_init_mode "$@"
    [ "$MODE" != bundle ] || func_1_0b_load_gitlab
    func_1_4_init_dir "$@"
    func_1_5_init_file "$@"
    func_1_6_init_bundle "$@"
    func_1_7_check_deps

    case "$MODE" in
        record) func_2_0_record ;;
        apply)  func_3_0_apply ;;
        bundle)
            func_4_0_bundle
            func_4_1_bundle_next_steps
            ;;
    esac
}

main "$@"
