#!/bin/bash
set -e

# adopt-dir.sh -- Bring ONE never-managed directory under repo management.
#
# One directory per run, and no loop. The directories this exists for were
# missed precisely because they had no marker to find, so there is no reliable
# thing to iterate over -- the operator names them, having seen them in a
# verification report. Run it twice for two directories.
#
# It does NOT edit default.xml. The manifest line goes to stdout with
# instructions, and the operator pastes it. Editing that file by machine means
# parsing and rewriting XML that every clone of this SDK depends on, to save one
# paste; and a wrong insertion breaks `repo sync` for everybody. The paste is
# also the review step -- the one moment a human looks at what will be added.
#
# ============================================================================
# 1_0  Libraries
# ============================================================================

# func_1_0_load_libs: source the shared libraries.
#
# The same libraries 2-rebuild.sh uses, doing the same jobs: this tool differs
# from that one in WHICH directories it accepts and in producing one manifest
# line instead of a whole file, not in how a repository is built. Reimplementing
# LFS ordering or token scrubbing here would be a second copy to keep correct.
func_1_0_load_libs(){
    local libs
    libs="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")/libs"

    . "$libs/utils.sh"   # first: everything below calls libutils_die
    . "$libs/args.sh"
    . "$libs/fstree.sh"
    . "$libs/gitrepo.sh"
    . "$libs/gitlab.sh"
    . "$libs/manifest.sh"
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
Usage: ${0##*/} --dir=DIR --dry-run
       ${0##*/} --dir=DIR --gitlab-url=URL --gitlab-group=G \\
           --git-user-name=NAME --git-user-email=EMAIL [--push --gitlab-token=PAT]
       ${0##*/} -h | --help

Take one directory that repo never managed, make it a git repository, push it to
GitLab, and print the manifest line that puts it back in the right place.

The remote is set whether or not you pass --push, at the credential-free SSH URL
built from --gitlab-url and --gitlab-group. So a run without --push leaves a
repository you can push yourself with a plain 'git push -u origin main', without
retyping the server details you already gave.

START WITH --dry-run. It builds nothing and needs no GitLab options: it prints
what the directory holds, by file type and by size, so you can decide what is
build output or scratch and write a .gitignore BEFORE anything is committed.
That order is not advice. A large file that enters git history can only be
removed by rewriting the history, which is not an option once it is pushed.

WHAT THIS IS FOR
  The vendor shipped some directories as plain files, with no .git symlink.
  2-rebuild.sh finds subprojects by looking for those symlinks, so a directory
  without one was never a repo project and was never rebuilt -- it is simply
  absent from a fresh 'repo sync'. In this SDK that is debian/ and ubuntu/.

  That is not a defect in 2-rebuild.sh. Those directories were not projects.
  Adopting them is a decision to manage something the vendor did not.

WHAT IT REFUSES
  A directory that already has a .git symlink. That is a repo project that
  2-rebuild.sh should handle; adopting it here would create a second repository
  for content that already has one.

  A directory that is itself a symlink. Committing one duplicates its target's
  content on the server, and a later sync would replace the link with a real
  directory. Those belong in the manifest as <linkfile>, not as projects.

  A directory holding a real repository with commits. Its history would be
  destroyed. Move or delete it by hand first if that is genuinely what you want.

Required:
  --dir=DIR              The directory to adopt. Its path relative to the SDK
                         root becomes the manifest path=, so it must be inside
                         the SDK tree.

Required unless --dry-run:
  --gitlab-url=URL       e.g. --gitlab-url=http://gitlab.example.com
  --gitlab-group=GROUP   The group to create the project in, e.g. RK3576
  --git-user-name=NAME   Value for git config user.name
  --git-user-email=EMAIL Value for git config user.email

Options:
  --dry-run              Survey the directory and exit. Creates nothing, needs
                         no credentials, touches no server. Use it first.
  --sdk-root=DIR         The SDK root that path= is computed against.
                         default: the directory --dir sits in
                         Give it when adopting something nested, so that
                         debian/overlay does not become a project called
                         "overlay" at the top level.
  --push                 Create the GitLab project and push. Without it nothing
                         leaves this machine: the repository is built and
                         committed locally, the remote is still set, and the
                         manifest line is printed -- so you can rehearse the
                         whole thing and then push by hand when it looks right.
  --gitlab-token=PAT     Required by --push. Needs api scope. Never written to
                         disk: it is spliced into the push URL, and scrubbed
                         from .git/config by a trap that fires on Ctrl-C too.
  --branch=NAME          Branch to create and push. default main
                         Must match the manifest's default revision, or
                         'repo sync' finds no such branch.
  --remote=NAME          Name for the remote. default origin
  --lfs-min-mb=N         Track files at or above this size with Git LFS.
                         default 50
                         Relevant here: these directories are where the rootfs
                         tarballs live, and a 1.3G blob in ordinary git history
                         cannot be moved to LFS afterwards without a rewrite.
  --commit-msg=TEXT      default "Adopt into repo management"
  --visibility=V         private, internal or public. default private
  -h, --help             Print this text and exit. Changes nothing.

  Underscores and hyphens are interchangeable. Both --key=value and --key value
  are accepted.

ON .gitignore
  This tool never writes one. What counts as junk depends on what the directory
  is -- *.o and .tmp_versions in a kernel tree, output/ in buildroot -- and a
  stale .o is byte-identical to a shipped one, so no rule can tell them apart.
  You write the file; --dry-run is what tells you what to put in it.

  Whatever a .gitignore excludes stays excluded, and the run says how many files
  that was. A non-zero count is worth reading: the vendor's own .gitignore is
  sometimes wrong once content is flattened into one repository -- docs/.gitignore
  excludes cn/ and en/, which hold 322 PDFs that no build failure would miss.

AFTER IT RUNS
  It prints the manifest line and then the exact steps to get that line into
  the manifest repository and into an existing 'repo sync' workspace. Read
  those; this tool deliberately stops at your clipboard.

Exit status:
  0  surveyed, or built and pushed if asked, and the line printed
  1  refused, or something failed. Nothing is half-done on purpose: the line is
     printed last, so seeing it means every step before it succeeded.
EOF
}

# ============================================================================
# 1_2  Option vocabulary
# ============================================================================

# func_1_2_check_options: define the accepted options and reject anything else.
#
# $@ -- the caller's raw arguments
#
# A typo'd --lfs-min-mb here is not a slow run as it would be elsewhere: it is a
# 1.3G tarball committed as an ordinary blob, which cannot be moved into LFS
# afterwards without rewriting history that has already been pushed.
func_1_2_check_options(){
    OPTION_NAMES="dir sdk-root gitlab-url gitlab-group gitlab-token \
git-user-name git-user-email branch remote lfs-min-mb commit-msg visibility push \
dry-run help"

    libargs_check_known "$OPTION_NAMES" "$@"
}

# ============================================================================
# 1_3  The directory
# ============================================================================

# func_1_3_init_dir: resolve the directory and the root its path is relative to.
#
# $@ -- the caller's raw arguments
#
# The symlink check runs on the name as typed, BEFORE any resolution. Resolving
# first would silently turn "adopt the symlink common" into "adopt
# device/rockchip/common", creating a duplicate of content that already has a
# project -- so the check has to see what the operator actually wrote.
func_1_3_init_dir(){
    local dir root

    libargs_has dir "$@" || libutils_die "no --dir given (try --help)"
    dir=$(libargs_get dir "" "$@")
    [ -n "$dir" ] || libutils_die "--dir is empty"

    # Before resolution, and before -d: a symlink to a directory passes -d.
    libgitrepo_check_symlink_dir "$dir"

    [ -d "$dir" ] || libutils_die "not a directory: $dir"
    [ -r "$dir" ] || libutils_die "directory is not readable: $dir"
    [ -w "$dir" ] || libutils_die "directory is not writable: $dir (a repository must be created inside it)"

    DIR=$(cd "$dir" && pwd -P)

    # Default: the parent. Correct for a top-level directory like debian/, which
    # is what this tool is for, and wrong in a way that is immediately visible
    # for anything nested -- the printed path= would read "overlay" rather than
    # "debian/overlay", and the operator reviewing the line sees that before it
    # reaches the manifest.
    root=$(libargs_get sdk-root "$(dirname "$DIR")" "$@")
    [ -d "$root" ] || libutils_die "--sdk-root is not a directory: $root"
    SDK_ROOT=$(cd "$root" && pwd -P)

    case "$DIR/" in
        "$SDK_ROOT"/*) ;;
        *) libutils_die "--dir ($DIR) is not inside --sdk-root ($SDK_ROOT)" ;;
    esac

    [ "$DIR" != "$SDK_ROOT" ] || \
        libutils_die "--dir and --sdk-root are the same directory; a project's path cannot be empty"

    REL="${DIR#"${SDK_ROOT}"/}"

    # The same rule 2-rebuild.sh uses. It must be the same: two tools that
    # disagree about naming produce a manifest whose lines point at repositories
    # nobody pushed. Slashes fold to dashes because GitLab projects live in one
    # flat group while the layout is carried by the manifest's path=.
    REPO_NAME=$(echo "$REL" | tr '/' '-')
}

# ============================================================================
# 1_4  Refusals
# ============================================================================

# func_1_4_check_unmanaged: refuse anything that is already managed.
#
# This is the check that makes this tool distinct from 2-rebuild.sh, and it is
# the exact inverse of that script's precondition. 2-rebuild.sh requires a .git
# symlink -- the vendor's marker that a directory WAS a repo project. This tool
# requires its absence, because "never managed" is the whole target.
#
# Both refusals protect against creating a second repository for content that
# already has one: the duplicate would push the same files to a different
# project name, and the manifest would then have two projects wanting the same
# path -- a 'repo sync' that fails for everyone, from a line that looked fine.
func_1_4_check_unmanaged(){
    cd "$DIR"

    if libgitrepo_has_evidence; then
        libutils_die "$DIR has a .git symlink -> $(readlink .git)
     This WAS a repo project, so it is 2-rebuild.sh's job, not this tool's.
     Adopting it here would create a second repository for content that
     already has one."
    fi

    if [ -e "$LIBGITREPO_EVIDENCE_FILE" ]; then
        libutils_die "$DIR holds $LIBGITREPO_EVIDENCE_FILE
     2-rebuild.sh has already reclaimed this directory. It is managed."
    fi

    # State 2 of libgitrepo_is_real_repo: a real repository carrying commits.
    # Refused rather than reused, because this tool's next act is to build a
    # fresh import, and doing that over existing history destroys it.
    if libgitrepo_is_real_repo; then
        libutils_die "$DIR already holds a git repository with commits ($(git rev-parse --short HEAD))
     Refusing to touch it. If you really mean to re-import from scratch,
     move or delete its .git by hand first -- deliberately, not as a
     side effect of running this."
    fi
}

# ============================================================================
# 1_5  GitLab configuration
# ============================================================================

# func_1_5_init_gitlab_config: read the server options.
#
# $@ -- the caller's raw arguments
#
# Skipped entirely under --dry-run, which is what lets a survey run with no
# credentials and no server details at all. Demanding them for a read-only look
# at a local directory would be the thing that stops anyone from looking.
#
# Outside a dry run, URL and group are required even without --push, because
# they appear in the printed manifest line: a rehearsal that prints a line with
# an empty fetch base is a rehearsal of the wrong thing.
func_1_5_init_gitlab_config(){
    GITLAB_TOKEN=$(libargs_get gitlab-token "" "$@")

    if [ "$DRY_RUN" = yes ]; then
        return 0
    fi

    GITLAB_URL=$(libargs_get gitlab-url "" "$@")
    [ -n "$GITLAB_URL" ] || \
        libutils_die "missing required option: --gitlab-url (e.g. --gitlab-url=http://gitlab.example.com)"

    GITLAB_GROUP=$(libargs_get gitlab-group "" "$@")
    [ -n "$GITLAB_GROUP" ] || \
        libutils_die "missing required option: --gitlab-group (the GitLab group to push into)"

    VISIBILITY=$(libargs_get visibility "private" "$@")
    case "$VISIBILITY" in
        private|internal|public) ;;
        *) libutils_die "--visibility must be private, internal or public (got '$VISIBILITY')" ;;
    esac
}

# ============================================================================
# 1_6  Git configuration
# ============================================================================

func_1_6_init_git_config(){
    BRANCH=$(libargs_get branch "main" "$@")
    [ -n "$BRANCH" ] || libutils_die "--branch was given an empty value"

    REMOTE=$(libargs_get remote "origin" "$@")
    [ -n "$REMOTE" ] || libutils_die "--remote was given an empty value"

    # Not needed to survey a directory: nothing is committed, so there is no
    # commit to attribute to anyone.
    if [ "$DRY_RUN" = yes ]; then
        return 0
    fi

    GIT_USER_NAME=$(libargs_get git-user-name "" "$@")
    [ -n "$GIT_USER_NAME" ] || \
        libutils_die "missing required option: --git-user-name (value for git config user.name)"

    GIT_USER_EMAIL=$(libargs_get git-user-email "" "$@")
    [ -n "$GIT_USER_EMAIL" ] || \
        libutils_die "missing required option: --git-user-email (value for git config user.email)"

    COMMIT_MSG=$(libargs_get commit-msg "Adopt into repo management" "$@")
    [ -n "$COMMIT_MSG" ] || libutils_die "--commit-msg was given an empty value"
}

# ============================================================================
# 1_7  LFS configuration
# ============================================================================

func_1_7_init_lfs_config(){
    LFS_MIN_MB=$(libargs_get lfs-min-mb "50" "$@")
    libgitrepo_check_min_mb "$LFS_MIN_MB"
}

# ============================================================================
# 1_8  Mode
# ============================================================================

# func_1_8_init_mode: decide how far this run goes.
#
# Three depths: survey only, build locally, build and push. Read before the
# other option groups need it, because --dry-run is what makes most of them
# optional.
#
# The token is demanded here rather than at the point of use, because by then
# the repository is built and the operator would have to re-run anyway. This is
# the last moment where failing costs nothing.
func_1_8_init_mode(){
    if libargs_is_true push "$@"; then
        DO_PUSH=yes
        [ "$DRY_RUN" = no ] || libutils_die "--dry-run and --push contradict each other: one surveys, the other publishes"
        [ -n "$GITLAB_TOKEN" ] || libutils_die "--push needs --gitlab-token (api scope)"
    else
        DO_PUSH=no
    fi
}

# ============================================================================
# 1_9  Dependency check
# ============================================================================

# func_1_9_check_deps: die unless the tools this run needs are present.
#
# A dry run needs only find, du and awk -- all of which coreutils guarantees --
# so it deliberately does not demand git-lfs. Someone surveying a directory to
# decide whether it is worth adopting should not be blocked by a dependency of
# the step they have not reached.
#
# libgitrepo_require_lfs rather than a bare check for the binary: a git-lfs
# whose filters were never installed passes `command -v` and then fails at
# `git lfs track` -- after the commit, in the one place where recovery means
# rewriting history.
func_1_9_check_deps(){
    libutils_require_cmd find du awk sort

    [ "$DRY_RUN" = no ] || return 0

    libutils_require_cmd git curl
    libgitrepo_require_lfs
}

# ============================================================================
# 1_10  Configuration report
# ============================================================================

# func_1_10_report_config: print what this run will do, before it does it.
#
# On stderr, before any work. Its purpose is to let the operator stop a run
# pointed at the wrong directory, which only works if it appears first.
func_1_10_report_config(){
    libutils_say "directory:   ${DIR}"
    libutils_say "sdk root:    ${SDK_ROOT}"
    libutils_say "manifest path:  ${REL}"
    libutils_say "project name:   ${REPO_NAME}.git"

    if [ "$DRY_RUN" = yes ]; then
        libutils_say "mode:        DRY RUN -- survey only, nothing is created"
        echo >&2
        return 0
    fi

    libutils_say "branch:      ${BRANCH}"
    libutils_say "remote:      ${REMOTE} -> $(libgitlab_ssh_url "$GITLAB_URL" "$GITLAB_GROUP" "$REPO_NAME")"
    libutils_say "LFS:         files >= ${LFS_MIN_MB}MB"
    if [ "$DO_PUSH" = yes ]; then
        libutils_say "push:        YES -> $(libgitlab_repo_url "$GITLAB_URL" "$GITLAB_GROUP" "$REPO_NAME")"
    else
        libutils_say "push:        no (built locally, remote set; push by hand or re-run with --push)"
    fi
    echo >&2
}

# ============================================================================
# 1_11  Survey
# ============================================================================

# func_1_11_survey: print what the directory holds, and stop.
#
# The whole point of the tool having a dry run. What counts as junk -- *.o in a
# kernel tree, output/ in buildroot, a stale .tar.xz -- is a judgement about
# intent, and a stale .o is byte-identical to a shipped one, so no rule can make
# it. This prints the two views that let a person make it: by file type, and by
# what is actually taking up the space.
#
# Before the repository exists, deliberately. A large file that has entered git
# history can only be removed by rewriting that history.
func_1_11_survey(){
    libutils_say "surveying ${DIR} ..."
    echo >&2

    cat <<EOF
============================================================================
SURVEY: ${REL}
============================================================================
total size   $(du -sh "$DIR" 2>/dev/null | cut -f1)
files        $(find "$DIR" -mindepth 1 \( -name .git -o -name .repo -o -name .hooks \) -prune -o -type f -print 2>/dev/null | wc -l)
symlinks     $(find "$DIR" -mindepth 1 \( -name .git -o -name .repo -o -name .hooks \) -prune -o -type l -print 2>/dev/null | wc -l)
.gitignore   $(func_1_11_gitignore_note)

BY FILE TYPE (largest total first)
$(func_1_11_table_ext)

BIGGEST ENTRIES (directories totalled)
$(func_1_11_table_big)

WHAT TO DO WITH THIS
  Decide which of the above is build output or scratch, and write a .gitignore
  in ${DIR}
  listing it. Nothing here does that for you: a stale .o and a shipped .o are
  the same bytes, so the judgement is yours.

  Common patterns, as a starting point and not a recommendation:
    *.o *.a *.so.debug      compiled objects
    output/ build/          whole build trees
    *.tmp *.part *~ .*.swp  scratch and editor files

  Then run again without --dry-run. It will report how many files your
  .gitignore excluded, so you can check the rule did what you meant.

  Anything at or above the LFS threshold (default 50MB) that you KEEP will be
  tracked by Git LFS automatically. You do not need a rule for that.
EOF
}

# func_1_11_gitignore_note: say whether the directory already has a .gitignore.
#
# Worth its own line because the two cases lead somewhere different: an existing
# one is the vendor's and may already be excluding real content, while its
# absence means git will take literally everything listed above.
func_1_11_gitignore_note(){
    local n
    n=$(find "$DIR" -name .gitignore -not -path '*/.git/*' 2>/dev/null | wc -l)

    if [ "$n" -eq 0 ]; then
        echo "none -- git would commit everything listed below"
    else
        echo "$n found (already excluding something; the real run reports how much)"
    fi
}

# func_1_11_table_ext / func_1_11_table_big: format the two survey tables.
#
# The libs return bytes so that both speak one unit; the human-readable
# conversion happens here, once, at the edge where it is displayed.
#
# AWK_HR is a shared awk function definition rather than a copy in each table,
# so the two can never start disagreeing about what 1.3G means.
AWK_HR='
function hr(b) {
    split("B KB MB GB TB", u, " "); i = 1
    while (b >= 1024 && i < 5) { b /= 1024; i++ }
    return sprintf("%.1f%s", b, u[i])
}'

func_1_11_table_ext(){
    libfstree_ext_histogram "$DIR" \
        | awk -F'\t' "$AWK_HR"'
            BEGIN { printf "  %8s  %10s  %s\n", "COUNT", "SIZE", "TYPE" }
            { printf "  %8d  %10s  %s\n", $1, hr($2), $3 }'
}

func_1_11_table_big(){
    libfstree_biggest "$DIR" 15 \
        | awk -F'\t' "$AWK_HR"'
            { printf "  %10s  %s\n", hr($1), $2 }'
}

# ============================================================================
# 2_0  Build
# ============================================================================

# func_2_0_build: make the directory into a committed git repository.
#
# Runs with the shell inside DIR. The LFS step precedes staging and that order
# is load-bearing, not stylistic: a 1.3G tarball that enters history as an
# ordinary blob can only be moved to LFS by rewriting history, which is not
# something to discover after a push.
func_2_0_build(){
    cd "$DIR"

    libgitrepo_init "$BRANCH"

    git config user.name "$GIT_USER_NAME"
    git config user.email "$GIT_USER_EMAIL"

    libgitrepo_setup_lfs "$LFS_MIN_MB"

    # No force-add list. 2-rebuild.sh needs one because some vendor .gitignore
    # files exclude paths that used to be nested projects; a never-managed
    # directory has no such history, so anything its .gitignore excludes was
    # meant to be excluded. If a build later reveals otherwise, that is the
    # signal to come back -- not to guess now.
    libgitrepo_stage ""

    IGNORED=$(libgitrepo_count_ignored)
    if [ "$IGNORED" -gt 0 ]; then
        libutils_say "${IGNORED} file(s) excluded by .gitignore and NOT committed."
        libutils_say "  Check the rule did what you meant, especially the count:"
        libutils_say "  cd $DIR && git ls-files --others --ignored --exclude-standard"
    fi

    libgitrepo_commit "$COMMIT_MSG" "$COMMIT_MSG"

    HEAD_SHA=$(libgitrepo_head)
}

# ============================================================================
# 3_0  Remote and push
# ============================================================================

# func_3_0_push: set the remote, and push it if asked.
#
# The remote is set either way. Without --push nothing leaves the machine, but
# the server details were already given on the command line, so withholding the
# remote would mean the operator has to retype what they already told us before
# they can `git push` by hand. A remote is a note about where this belongs, not
# an act of publishing.
#
# Set AFTER the push, not before: libgitlab_push replaces origin with a
# token-bearing URL and scrubs the token afterwards, which would leave a
# credential-free HTTP remote in place of our SSH one.
#
# The verify step is not ceremony. `git push` exiting 0 is weaker evidence than
# it looks -- a stale remote or a server-side hook can leave the branch
# elsewhere -- and the manifest line printed afterwards is a promise that this
# repository is fetchable at this branch.
func_3_0_push(){
    cd "$DIR"

    if [ "$DO_PUSH" = yes ]; then
        libgitlab_ensure_project "$GITLAB_URL" "$GITLAB_GROUP" "$REPO_NAME" \
            "$GITLAB_TOKEN" "$VISIBILITY"

        libgitlab_push "$GITLAB_URL" "$GITLAB_GROUP" "$REPO_NAME" \
            "$GITLAB_TOKEN" "$BRANCH"

        libgitlab_verify_push "$GITLAB_URL" "$GITLAB_GROUP" "$REPO_NAME" \
            "$GITLAB_TOKEN" "$BRANCH" "$HEAD_SHA"
    fi

    libgitlab_setup_remote "$GITLAB_URL" "$GITLAB_GROUP" "$REPO_NAME" "$REMOTE"
    libutils_say "remote ${REMOTE}: $(git remote get-url "$REMOTE")"

    if [ "$DO_PUSH" != yes ]; then
        libutils_say "not pushed (no --push). To push it yourself:"
        libutils_say "  cd $DIR && git push -u ${REMOTE} ${BRANCH}"
    fi
}

# ============================================================================
# 4_0  The manifest line
# ============================================================================

# func_4_0_manifest_line: print the one line to paste, and nothing else.
#
# To stdout, alone, so it can be captured:
#     adopt-dir.sh --dir=... 2>/dev/null >> lines.txt
# Everything else this script prints goes to stderr for exactly that reason.
func_4_0_manifest_line(){
    libmanifest_line "$REL" "$REPO_NAME"
}

# ============================================================================
# 4_1  What to do next
# ============================================================================

# func_4_1_next_steps: the manual half, spelled out.
#
# On stderr, because it is instruction and not output.
#
# Long on purpose. This tool stops at the operator's clipboard, so the steps
# after it are the ones nobody has automated and therefore the ones most likely
# to be got wrong or forgotten -- and forgetting them means a pushed repository
# no manifest mentions, which is invisible until someone syncs a fresh tree and
# comes up short.
#
# The line to paste is repeated here in full rather than described. Every step
# is something to run or paste; asking the operator to reconstruct the line from
# a path= and a name= printed separately is asking them to retype what we
# already have. There is deliberately no "check path= and name= are correct"
# step: both are computed here from --dir and --sdk-root, so re-reading them
# only confirms this script agrees with itself. What is worth checking is what
# git ended up with, which is why the remote is shown as a command to run.
func_4_1_next_steps(){
    local line manifest_repo
    line=$(func_4_0_manifest_line)
    manifest_repo="the directory holding default.xml (your manifest clone)"

    cat >&2 <<EOF

============================================================================
NEXT STEPS -- none of this happened automatically
============================================================================

STEP 1. Put this line in the manifest, immediately before </manifest>:

${line}

    cd ${manifest_repo}
    \$EDITOR default.xml

  Paste it as the last <project> line. Order does not matter to repo, so the
  end is simply where it is easiest to review in a diff.

  Do NOT regenerate default.xml with 2-rebuild.sh after this. That rebuilds
  the file from the .git symlinks it can find, and this directory has none --
  your line would be silently dropped.

STEP 2. Commit and push the manifest:

    git diff                      # expect exactly one added line
    git add default.xml
    git commit -m "Add ${REL} project"
    git push

  If 3-publish-manifest.sh is what you use to publish, run it instead -- it
  refuses to commit anything but default.xml and .gitignore, which matters
  because build logs in that directory contain the token in plaintext.

STEP 3. Update a workspace that was already synced.

  An existing 'repo sync' tree does not learn about a new project on its own;
  it re-reads the manifest first. From the root of that workspace:

    cd <workspace>
    repo init -u <same manifest URL> -b ${BRANCH}
    repo sync ${REL}

  The 'repo init' is what re-reads the manifest; the 'repo sync' then fetches
  just this one project. 'repo sync' with no argument works too and is slower.
  Naming the path is also the safer habit: it cannot touch the other projects.

  Verify it arrived, and that LFS content came with it:

    ls -la <workspace>/${REL}
    du -sh <workspace>/${REL}      # compare against the original

  A repository with LFS files clones as small pointer files when git-lfs is
  missing on the machine doing the sync. The size comparison is what catches
  that; a directory listing looks perfectly normal.

STEP 4. Re-verify against the original:

    4-verify-sync.sh --baseline-dir=<original>/${REL} \\
                     --candidate-dir=<workspace>/${REL}

  Expect a clean result except permissions: git carries only the owner execute
  bit, so group and other bits come from the umask of the shell that ran the
  sync. Section 5 says so explicitly when that is all it found.

TO SEE WHAT THIS RUN ACTUALLY CONFIGURED, ask git rather than trusting the
narration above:

    cd ${DIR}
    git config --list --local     # user.name, user.email, remote, lfs filters
    git remote -v                 # expect ${REMOTE} at the ssh:// URL
    git log --stat -1             # what went into the commit
    git lfs ls-files              # which files became pointers

EOF
}

# ============================================================================
# main
# ============================================================================

# main: order matters. Every refusal fires before anything is created, and the
# manifest line is printed last -- so seeing it means every step succeeded.
#
# DRY_RUN is read first, before the option groups, because it is what makes most
# of them optional.
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

    if libargs_is_true dry-run "$@"; then
        DRY_RUN=yes
    else
        DRY_RUN=no
    fi

    func_1_3_init_dir "$@"
    func_1_4_check_unmanaged
    func_1_5_init_gitlab_config "$@"
    func_1_6_init_git_config "$@"
    func_1_7_init_lfs_config "$@"
    func_1_8_init_mode "$@"
    func_1_9_check_deps
    func_1_10_report_config

    # Stops here on purpose. The survey exists to be read and acted on before a
    # repository exists, so continuing into the build would defeat it.
    if [ "$DRY_RUN" = yes ]; then
        func_1_11_survey
        exit 0
    fi

    func_2_0_build
    func_3_0_push

    libutils_say ""
    libutils_say "MANIFEST LINE (stdout; everything else is stderr):"
    func_4_0_manifest_line
    func_4_1_next_steps
}

main "$@"
