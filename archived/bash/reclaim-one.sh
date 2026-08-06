#!/usr/bin/env bash
#
# reclaim-one.sh -- Reclaim ONE directory of a repo-stripped SDK into GitLab.
#
# Scope: exactly one directory per invocation. No recursion, no batching, and
# no knowledge of any enclosing tree.
#
# Why that scope IS the design:
#   - The reassembled SDK's directory layout is expressed in the repo manifest
#     (<project name="mpp" path="external/mpp"/>), NOT in repository names. So
#     a per-directory worker has no need to know where the SDK root is. Making
#     it know caused a real bug: an unrelated SDK_ROOT left over in the
#     operator's environment decided whether the script ran at all.
#   - 55 directories each fail differently. A per-directory script you re-run
#     after fixing one thing beats a batch script that dies at number 37.
#
# The repository name therefore comes from the directory's own basename. A
# future reclaim-all.sh walks the tree, calls this script once per hit, and is
# the only thing that needs to know about paths and the manifest.
#
# Design rules:
#   1. Respect the vendor's surviving .gitignore. Do NOT second-guess it.
#      Compilation is the judge, not this script. The sole exception is
#      --force-add; libgitrepo_stage() documents why it has to exist.
#   2. Idempotent. Safe to re-run at any point. Never destroys SDK content:
#      the dangling .git symlink is moved aside, never deleted.
#   3. The PAT is written to no file except .git/config, for the duration of
#      the push only, and is scrubbed by an EXIT trap that fires on Ctrl-C too.
#
# Structure: every statement lives inside a function; main() is the only
# caller. Nothing runs at file scope except the final main dispatch, so this
# file can be sourced to test one function in isolation.
#
# Usage:
#   ./reclaim-one.sh --gitlab-token=glpat-xxxx [options] [directory]
#
# The directory defaults to '.', so the common case is to cd there first:
#   cd .../rk3576-linux-6.1/external/mpp && ./reclaim-one.sh --gitlab-token=$T
#
# Options:
#   --gitlab-token=TOKEN   required unless --dry-run; scopes: api, write_repository
#   --gitlab-url=URL       default http://gitlab.example.com
#   --gitlab-group=GROUP   default team_rk3576
#   --project-name=NAME    default: the directory's basename
#   --branch=BRANCH        default main
#   --visibility=LEVEL     default private; private|internal|public
#   --lfs-min-mb=N         default 50; files at or above this size go to LFS
#   --force-add="a b"      git add -f these paths despite .gitignore
#   --allow-no-evidence    proceed even with no .git symlink proving this
#                          location was once a repo project
#   --dry-run              stop after the local commit; touch no server
#   --help                 print this text and exit
#
# Examples:
#   # docs/.gitignore excludes cn/ and en/, which were themselves repo projects
#   # and hold 322 PDFs. Flattening them in is a human decision:
#   ./reclaim-one.sh --gitlab-token=$T --force-add="cn en" docs
#
#   # rehearse locally without creating anything on the server:
#   ./reclaim-one.sh --dry-run

# ---------------------------------------------------------------------------
# Library loading
# ---------------------------------------------------------------------------

# script_dir: print the directory holding this script.
#
# Uses BASH_SOURCE rather than $0 so it stays correct when the file is sourced
# for testing, and readlink -f so it survives being invoked through a symlink
# placed on PATH -- which is how this ends up being used once the operator
# tires of typing the full path.
script_dir() {
    dirname "$(readlink -f "${BASH_SOURCE[0]}")"
}

# load_libs: source every library this script depends on.
#
# Ordered by dependency: utils first, because every other library calls libutils_die().
load_libs() {
    local libs
    libs="$(script_dir)/libs"

    . "$libs/utils.sh"
    . "$libs/args.sh"
    . "$libs/gitrepo.sh"
    . "$libs/gitlab.sh"
}

# ---------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------

# option_names: print every option this script accepts, space separated.
#
# Single source of truth, handed to libargs_check_known so a misspelled option is
# an error instead of a silent fall back to a default. Must be edited together
# with read_options below.
option_names() {
    echo "gitlab-token gitlab-url gitlab-group project-name branch" \
         "visibility lfs-min-mb force-add allow-no-evidence dry-run help"
}

# flag_names: print the subset of options that take no value.
#
# libargs_positional needs this to tell `--dry-run docs` (flag, then a directory)
# apart from `--branch main` (option, then its value). Without it the directory
# is swallowed as --dry-run's value and the script quietly works on '.' instead
# -- a wrong result that looks like a right one.
flag_names() {
    echo "allow-no-evidence dry-run help"
}

# show_help: print this file's header comment as the help text.
#
# Reads the header instead of duplicating it, because a help string that drifts
# away from the documentation above it is worse than no help string. Prints
# from line 2 to the first blank line, stripping the leading '#'.
show_help() {
    sed -n '2,/^$/{ s/^#\{1,2\} \{0,1\}//; p; }' "$(readlink -f "${BASH_SOURCE[0]}")"
}

# read_options: validate the argument list and set the run's configuration.
#
# $@ -- the caller's raw arguments
#
# Every value the rest of the run needs is set here and nowhere else, so there
# is exactly one place to look when a run misbehaves. The defaults live here
# too, rather than scattered across the functions that consume them.
read_options() {
    libargs_check_known "$(option_names)" "$@"

    TOKEN=$(libargs_get gitlab-token "" "$@")
    GITLAB_URL=$(libargs_get gitlab-url "http://gitlab.example.com" "$@")
    GITLAB_GROUP=$(libargs_get gitlab-group "team_rk3576" "$@")
    BRANCH=$(libargs_get branch "main" "$@")
    VISIBILITY=$(libargs_get visibility "private" "$@")
    LFS_MIN_MB=$(libargs_get lfs-min-mb "50" "$@")
    FORCE_ADD=$(libargs_get force-add "" "$@")

    if libargs_is_true dry-run "$@"; then DRY_RUN=yes; else DRY_RUN=no; fi
    if libargs_is_true allow-no-evidence "$@"; then
        ALLOW_NO_EVIDENCE=yes
    else
        ALLOW_NO_EVIDENCE=no
    fi

    # The target directory is the only positional argument. Defaulting it to
    # '.' makes "cd there and run it" the shortest path, which is how this is
    # actually used.
    TARGET=$(libargs_positional 0 "." "$(flag_names)" "$@")

    # A dry run needs no credential, and demanding one would discourage the
    # rehearsal that catches mistakes before they reach the server.
    if [ -z "$TOKEN" ] && [ "$DRY_RUN" = no ]; then
        libutils_die "missing required option: --gitlab-token (or pass --dry-run)"
    fi

    case "$VISIBILITY" in
        private|internal|public) ;;
        *) libutils_die "--visibility must be private, internal or public (got '$VISIBILITY')" ;;
    esac

    # Validated in the library, next to the libgitrepo_find_big arithmetic that
    # imposes the constraint, so this script and 2-rebuild.sh cannot drift on
    # what counts as a valid threshold.
    libgitrepo_check_min_mb "$LFS_MIN_MB"
}

# enter_target: cd into the directory to reclaim and settle its project name.
#
# $@ -- the caller's raw arguments, needed for the --project-name lookup
#
# Everything after this point operates on the current working directory. That
# is what keeps the gitrepo and gitlab libraries free of any path logic.
#
# The name defaults to the physical basename. Two directories elsewhere in the
# SDK might share a basename; if that happens, GitLab reports the collision and
# the operator passes --project-name. We do not pre-empt it by folding the path
# into the name, because the path belongs in the manifest.
enter_target() {
    # Checked BEFORE the cd, while we still have the name the operator typed.
    # After cd, a symlinked directory is indistinguishable from its target.
    libgitrepo_check_symlink_dir "$TARGET"

    cd "$TARGET" 2>/dev/null \
        || libutils_die "not a directory: $TARGET (resolved from $PWD)"

    PROJECT_NAME=$(libargs_get project-name "$(basename "$(pwd -P)")" "$@")
    [ -n "$PROJECT_NAME" ] || libutils_die "cannot derive a project name from $(pwd -P)"
}

# check_evidence: require proof that this directory was once a repo project.
#
# A dangling .git symlink pointing into the deleted .repo/projects tree is that
# proof, and it is the reason this directory is a reclamation target rather than
# an arbitrary folder. Requiring it by default blocks the most expensive
# mistake available here: running one level too high and committing an entire
# subtree, other projects' .gitignore rules and all, into a single repository.
#
# --allow-no-evidence exists because 21 of the 55 known project roots have no
# surviving marker. Absence is a reason to look, not a reason to refuse.
check_evidence() {
    if libgitrepo_has_evidence; then
        libgitrepo_report_evidence
        return 0
    fi

    if [ -d .git ]; then
        libutils_say "no .git symlink, but a real .git is here -- treating as a re-run"
        return 0
    fi

    [ "$ALLOW_NO_EVIDENCE" = yes ] \
        || libutils_die "no .git here, so nothing proves $(pwd -P) was a repo project.
     If you are sure, re-run with --allow-no-evidence."

    libutils_warn "proceeding without evidence (--allow-no-evidence)"
}

# ---------------------------------------------------------------------------
# Commit message
# ---------------------------------------------------------------------------

# import_message: print the commit message for the initial import.
#
# Records WHY the tree looks the way it does. Six months from now that
# reasoning is not reconstructible from the diff -- in particular, nothing in a
# diff ever explains why a `-f` was necessary.
import_message() {
    echo "Import $PROJECT_NAME from rk3576-linux-6.1 SDK (Topeet)"
    echo
    echo "The vendor stripped the .repo metadata. This project was identified by"
    echo "its dangling .git symlink, and its .gitignore was applied unmodified."

    [ -n "$FORCE_ADD" ] || return 0
    echo
    echo "Force-added despite .gitignore: $FORCE_ADD"
    echo "Those paths were themselves repo projects, so the ignore rule was"
    echo "correct under the original multi-repo layout and is wrong here. Their"
    echo "loss would have been invisible to the build."
}

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

# report_result: print what happened and what the operator still has to do.
#
# The manifest line carries a placeholder for path= rather than a guess. This
# script does not know where the directory sits in the SDK, and a plausible
# looking wrong path is worse than an obvious blank.
#
# The ignored count is shown because it is the one number that can indicate a
# silent loss, together with the command to list the names -- a bare count
# cannot be acted on, and the decision it informs (whether --force-add is
# warranted) needs the names.
report_result() {
    echo
    libutils_say "done: $(pwd -P)"
    libutils_say "  project : $GITLAB_GROUP/$PROJECT_NAME"
    libutils_say "  commit  : $(libgitrepo_head)"
    libutils_say "  ignored : $(libgitrepo_count_ignored) file(s) excluded by .gitignore"
    libutils_say "            list them: git ls-files --others --ignored --exclude-standard"

    echo
    echo "manifest line (fill in path= relative to the SDK root):"
    echo "  <project name=\"$PROJECT_NAME\" path=\"FILL/ME/IN\" />"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

# main: the only entry point.
#
# The body below is almost entirely a sequence of library calls, which is the
# intent: the ordering is enforced here, once, rather than by each function
# re-checking its predecessors.
#
#   evidence -> init -> LFS -> add -> commit -> remote -> push -> verify
#                        ^^^
#      LFS must precede add, or a large blob enters history un-LFS'd and
#      converting it afterwards means rewriting history.
#
# `set -euo pipefail` is scoped to this function, so sourcing the file to test
# one function does not change the caller's shell options.
main() {
    set -euo pipefail

    load_libs

    # Handled before read_options so --help works with no token and no valid
    # target directory.
    if libargs_is_true help "$@"; then
        show_help
        return 0
    fi

    read_options "$@"
    enter_target "$@"

    libutils_say "directory : $(pwd -P)"
    libutils_say "project   : $GITLAB_GROUP/$PROJECT_NAME"

    check_evidence
    libgitrepo_clear_evidence
    libgitrepo_init "$BRANCH"
    libgitrepo_setup_lfs "$LFS_MIN_MB"
    libgitrepo_stage "$FORCE_ADD"
    libgitrepo_commit "$(import_message)" "Update $PROJECT_NAME from SDK tree"

    if [ "$DRY_RUN" = yes ]; then
        echo
        libutils_say "dry run: stopping before touching $GITLAB_URL"
        report_result
        return 0
    fi

    libgitlab_ensure_project "$GITLAB_URL" "$GITLAB_GROUP" "$PROJECT_NAME" \
        "$TOKEN" "$VISIBILITY"
    libgitlab_push "$GITLAB_URL" "$GITLAB_GROUP" "$PROJECT_NAME" "$TOKEN" "$BRANCH"
    libgitlab_verify_push "$GITLAB_URL" "$GITLAB_GROUP" "$PROJECT_NAME" "$TOKEN" "$BRANCH" "$(libgitrepo_head)"

    report_result
}

main "$@"
