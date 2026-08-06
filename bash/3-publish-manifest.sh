#!/bin/bash
set -e

# ============================================================================
# 1_0  Libraries
# ============================================================================

# func_1_0_load_libs: source the shared libraries.
#
# gitlab.sh IS sourced here, unlike in 2-rebuild.sh: this script pushes exactly
# one repository, which is the one-directory-per-invocation shape those
# functions assume.
func_1_0_load_libs(){
    local libs
    libs="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/libs"

    . "$libs/utils.sh"   # first: everything below calls libutils_die
    . "$libs/args.sh"
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
Usage: ${0##*/} --gitlab-url=URL --gitlab-group=GROUP --gitlab-token=TOKEN \\
           --git-user-name=NAME --git-user-email=ADDR [options]
       ${0##*/} -h | --help

Publish the default.xml produced by 2-rebuild.sh as a git repository, so that
colleagues can fetch the whole SDK with 'repo init' and 'repo sync'.

Reads default.xml from the current directory and turns that directory into the
manifest repository. Run it where 2-rebuild.sh ran.

Required options:
  --gitlab-url=URL      GitLab base address, e.g. http://gitlab.example.com
  --gitlab-group=GROUP  Group holding the SDK repositories.
  --gitlab-token=TOKEN  Personal Access Token; needs the api scope.
  --git-user-name=NAME  Value for git config user.name.
  --git-user-email=ADDR Value for git config user.email.

  No defaults, on purpose. A baked-in address publishes to the wrong host and
  reports success.

Optional:
  --project=NAME        Project name for the manifest itself.
                        default manifests
  --branch=BRANCH       Branch to publish on.        default main
  --commit-msg=MSG      Commit message.              default "Publish repo manifest"
  --visibility=LEVEL    private, internal or public. default private
  --dry-run             Run every check, then stop before creating or pushing
                        anything. Nothing is written except .gitignore.
  -h, --help            Print this text and exit. Checks nothing.

  Underscores and hyphens are interchangeable. Both --key=value and --key value
  are accepted.

Checks, all before anything is pushed:
  1. default.xml exists, ends with its closing tag, and lists >= 1 project.
     The closing tag is the real test: libmanifest_finish writes it last, so
     its presence means the run that produced the file completed.
  2. default.xml.part is absent. A leftover part file means the last rebuild
     was interrupted, so default.xml predates it and is stale.
  3. Every project named in default.xml exists on the server. Publishing a
     manifest that names a repository nobody pushed produces a 'repo sync'
     that fails halfway through, on a colleague's machine.
  4. The commit contains default.xml and .gitignore, and nothing else. This
     is a whitelist because build logs in this directory contain the PAT in
     plaintext -- git-lfs echoes the credentialed push URL -- and a commit is
     not something you can take back.

Outputs:
  .gitignore            Written if absent, excluding the build logs.
  This directory becomes a git repository on the named branch.

Afterwards, a colleague fetches the SDK with:
  repo init -u <manifest url> -b <branch>
  repo sync -j4
  They need git-lfs installed, or large files arrive as pointer stubs.
EOF
}

# ============================================================================
# 1_2  Option vocabulary
# ============================================================================

# func_1_2_check_options: define the accepted options and reject anything else.
#
# $@ -- the caller's raw arguments
#
# Without the whitelist a typo like --gitlab_ur=http://... is ignored and the
# run proceeds against no server while looking healthy.
func_1_2_check_options(){
    OPTION_NAMES="gitlab-url gitlab-group gitlab-token \
git-user-name git-user-email project branch commit-msg visibility dry-run help"

    libargs_check_known "$OPTION_NAMES" "$@"
}

# ============================================================================
# 1_3  Paths
# ============================================================================

# func_1_3_init_paths: name the files this script reads and writes.
#
# The current directory, not the script directory: 2-rebuild.sh writes its
# manifest where the operator was standing, and this script is its counterpart.
# Running it in the wrong place finds no default.xml and dies, so guessing here
# fails closed.
func_1_3_init_paths(){
    RUN_DIR="$(pwd -P)"
    MANIFEST_FILE="${RUN_DIR}/default.xml"
    MANIFEST_PART="${MANIFEST_FILE}.part"
}

# ============================================================================
# 1_4  GitLab server configuration
# ============================================================================

# func_1_4_init_gitlab_config: read the GitLab options.
#
# $@ -- the caller's raw arguments
#
# The token is required here, unlike in 2-rebuild.sh where a local-only run is
# useful. This script has no local-only mode: publishing is the whole job.
func_1_4_init_gitlab_config(){
    GITLAB_URL=$(libargs_get gitlab-url "" "$@")
    if [ -z "$GITLAB_URL" ]; then
        libutils_die "missing required option: --gitlab-url (e.g. --gitlab-url=http://gitlab.example.com)"
    fi

    GITLAB_GROUP=$(libargs_get gitlab-group "" "$@")
    if [ -z "$GITLAB_GROUP" ]; then
        libutils_die "missing required option: --gitlab-group (the group holding the SDK repositories)"
    fi

    GITLAB_TOKEN=$(libargs_get gitlab-token "" "$@")
    if [ -z "$GITLAB_TOKEN" ]; then
        libutils_die "missing required option: --gitlab-token (api scope)"
    fi
}

# ============================================================================
# 1_5  Git commit configuration
# ============================================================================

# func_1_5_init_git_config: read the git identity and commit options.
#
# $@ -- the caller's raw arguments
func_1_5_init_git_config(){
    GIT_USER_NAME=$(libargs_get git-user-name "" "$@")
    if [ -z "$GIT_USER_NAME" ]; then
        libutils_die "missing required option: --git-user-name (value for git config user.name)"
    fi

    GIT_USER_EMAIL=$(libargs_get git-user-email "" "$@")
    if [ -z "$GIT_USER_EMAIL" ]; then
        libutils_die "missing required option: --git-user-email (value for git config user.email)"
    fi

    DEFAULT_BRANCH=$(libargs_get branch "main" "$@")
    if [ -z "$DEFAULT_BRANCH" ]; then
        libutils_die "--branch was given an empty value"
    fi

    GIT_COMMIT_MSG=$(libargs_get commit-msg "Publish repo manifest" "$@")
    if [ -z "$GIT_COMMIT_MSG" ]; then
        libutils_die "--commit-msg was given an empty value"
    fi
}

# ============================================================================
# 1_6  Publication configuration
# ============================================================================

# func_1_6_init_publish_config: read where the manifest itself is published.
#
# $@ -- the caller's raw arguments
#
# Visibility is validated against the three values GitLab accepts, because the
# API reports a bad one as a generic 400 that says nothing about which field
# was wrong.
func_1_6_init_publish_config(){
    MANIFEST_PROJECT=$(libargs_get project "manifests" "$@")
    if [ -z "$MANIFEST_PROJECT" ]; then
        libutils_die "--project was given an empty value"
    fi

    VISIBILITY=$(libargs_get visibility "private" "$@")
    case "$VISIBILITY" in
        private|internal|public) ;;
        *) libutils_die "--visibility must be private, internal or public, got '$VISIBILITY'" ;;
    esac

    if libargs_is_true dry-run "$@"; then
        DRY_RUN=yes
    else
        DRY_RUN=no
    fi
}

# ============================================================================
# 1_7  Dependency check
# ============================================================================

# func_1_7_check_deps: die unless every external command this run needs exists.
#
# git-lfs is not required: this repository holds one small XML file. The SDK
# repositories that do need it were pushed by 2-rebuild.sh, which checks for it.
func_1_7_check_deps(){
    libutils_require_cmd git curl grep
}

# ============================================================================
# 1_8  Configuration report
# ============================================================================

# func_1_8_report_config: echo the settled configuration before acting on it.
#
# The token is reported as present/absent, never echoed.
func_1_8_report_config(){
    libutils_say "manifest   : ${MANIFEST_FILE}"
    libutils_say "GitLab     : ${GITLAB_URL}"
    libutils_say "group      : ${GITLAB_GROUP}"
    libutils_say "project    : ${MANIFEST_PROJECT} (${VISIBILITY})"
    libutils_say "branch     : ${DEFAULT_BRANCH}"
    libutils_say "committer  : ${GIT_USER_NAME} <${GIT_USER_EMAIL}>"
    if [ -n "${GITLAB_TOKEN}" ]; then
        libutils_say "token      : supplied"
    else
        libutils_say "token      : not supplied"
    fi
    if [ "${DRY_RUN}" = yes ]; then
        libutils_say "mode       : dry run, nothing will be pushed"
    fi
}

# ============================================================================
# Checks
# ============================================================================

# func_check_manifest: die unless default.xml is present, complete and non-empty.
#
# The closing-tag test is the load-bearing one. libmanifest_finish appends
# </manifest> and moves the file into place as its last two acts, so a file
# carrying that tag was produced by a run that reached the end. Checking it is
# therefore equivalent to checking completion, and needs no XML parser.
#
# A leftover .part is a separate failure: it means a later rebuild started and
# did not finish, so default.xml is the output of an earlier run and no longer
# describes the tree.
func_check_manifest(){
    [ -f "${MANIFEST_FILE}" ] \
        || libutils_die "no default.xml here -- run 2-rebuild.sh first, or cd to where it wrote one"

    grep -q '</manifest>' "${MANIFEST_FILE}" \
        || libutils_die "default.xml has no closing tag: the run that wrote it did not finish"

    MANIFEST_TOTAL=$(libmanifest_count "${MANIFEST_FILE}")
    [ "${MANIFEST_TOTAL}" -gt 0 ] \
        || libutils_die "default.xml lists no projects"

    if [ -f "${MANIFEST_PART}" ]; then
        libutils_die "${MANIFEST_PART} exists: a rebuild was interrupted, so default.xml is stale. Finish that run first."
    fi

    libutils_say "manifest: ${MANIFEST_TOTAL} project(s), closing tag present"
}

# func_check_projects: die unless every project in the manifest is on the server.
#
# All of them, not a sample. A manifest naming a repository that was never
# pushed produces a 'repo sync' that dies partway through on a colleague's
# machine, which is the most expensive place to discover it. One HEAD request
# each is cheap by comparison.
#
# The name attribute carries a .git suffix that the API does not want, so it is
# stripped. Only <project lines are read: <remote also has a name attribute, and
# matching it would query a project called "origin".
func_check_projects(){
    local names name missing=0

    names=$(grep '<project ' "${MANIFEST_FILE}" \
              | grep -o 'name="[^"]*"' \
              | sed 's/^name="//; s/"$//')

    libutils_say "checking ${MANIFEST_TOTAL} project(s) on ${GITLAB_URL} ..."

    for name in $names; do
        if ! libgitlab_project_exists \
               "${GITLAB_URL}" "${GITLAB_GROUP}" "${name%.git}" "${GITLAB_TOKEN}"; then
            libutils_warn "missing on server: ${GITLAB_GROUP}/${name%.git}"
            missing=$((missing + 1))
        fi
    done

    [ "$missing" -eq 0 ] \
        || libutils_die "$missing project(s) named in the manifest are not on the server -- push them before publishing"

    libutils_say "all ${MANIFEST_TOTAL} project(s) present on the server"
}

# func_write_gitignore: exclude everything in this directory except the manifest.
#
# 2-rebuild.sh leaves build logs here, and git-lfs prints the credentialed push
# URL, so those logs contain the PAT in plaintext. They must never be committed.
#
# Written rather than appended, and skipped when the file already exists, so an
# operator who edited it keeps their edits.
func_write_gitignore(){
    if [ -f .gitignore ]; then
        libutils_say ".gitignore exists, leaving it alone"
        return 0
    fi

    # default.xml.part is listed for completeness; func_check_manifest has
    # already refused to run while one exists.
    cat > .gitignore <<'EOF'
*.log
subprojects.txt
default.xml.part
lfs/
EOF
    libutils_say "wrote .gitignore"
}

# func_check_index: die unless the staged set is exactly what we intend to publish.
#
# A whitelist, not a blacklist. The risk being managed is a plaintext PAT in a
# build log, and a commit cannot be taken back -- so the question to ask is
# "is this one of the two files I meant to commit", not "does this look like a
# log". A blacklist would have to anticipate every name a secret might arrive
# under; this cannot.
#
# Runs after staging and before committing, so it also catches a file added by
# hand with 'git add -f' in an earlier session.
func_check_index(){
    local unexpected

    unexpected=$(git diff --cached --name-only | grep -vxE 'default\.xml|\.gitignore' || true)

    if [ -n "$unexpected" ]; then
        echo "$unexpected" >&2
        libutils_die "the staged files above are neither default.xml nor .gitignore -- refusing to commit, build logs here contain the token in plaintext"
    fi
}

# ============================================================================
# Publication
# ============================================================================

# func_publish: turn this directory into a repository and push it.
#
# libgitlab_push is used rather than a hand-built remote URL: it puts the token
# in .git/config only for the duration of the push and scrubs it from an EXIT
# trap that fires on Ctrl-C too. libgitlab_verify_push then asks the server what
# it actually has, because 'git push' exiting 0 does not prove the branch landed
# where we think, and confirms nothing was left on disk.
func_publish(){
    libgitrepo_init "${DEFAULT_BRANCH}"
    git config user.name "${GIT_USER_NAME}"
    git config user.email "${GIT_USER_EMAIL}"

    func_write_gitignore

    git add default.xml .gitignore
    func_check_index

    if [ "${DRY_RUN}" = yes ]; then
        libutils_say "dry run: would create ${GITLAB_GROUP}/${MANIFEST_PROJECT} and push ${DEFAULT_BRANCH}"
        return 0
    fi

    libgitrepo_commit "${GIT_COMMIT_MSG}" "${GIT_COMMIT_MSG}"

    libgitlab_ensure_project "${GITLAB_URL}" "${GITLAB_GROUP}" \
        "${MANIFEST_PROJECT}" "${GITLAB_TOKEN}" "${VISIBILITY}"

    libgitlab_push "${GITLAB_URL}" "${GITLAB_GROUP}" \
        "${MANIFEST_PROJECT}" "${GITLAB_TOKEN}" "${DEFAULT_BRANCH}"

    libgitlab_verify_push "${GITLAB_URL}" "${GITLAB_GROUP}" \
        "${MANIFEST_PROJECT}" "${GITLAB_TOKEN}" "${DEFAULT_BRANCH}" "$(libgitrepo_head)"
}

# func_report_clone: print the commands a colleague needs.
#
# The plain, credential-free URL from libgitlab_repo_url -- this text is meant
# to be pasted into a chat window.
func_report_clone(){
    local url
    url=$(libgitlab_repo_url "${GITLAB_URL}" "${GITLAB_GROUP}" "${MANIFEST_PROJECT}")

    echo
    libutils_say "published: ${url}"
    echo
    echo "Colleagues fetch the SDK with:"
    echo "  repo init -u ${url} -b ${DEFAULT_BRANCH}"
    echo "  repo sync -j4"
    echo
    echo "They need git-lfs installed first, or large files arrive as pointer stubs."
}

# ============================================================================
# main
# ============================================================================

# main: order matters. Every check runs before anything is created or pushed.
main(){
    func_1_0_load_libs

    # Before anything else, so --help works with no arguments and no GitLab
    # access at all -- and before the banner, which would otherwise be a lie.
    if libargs_is_true help "$@"; then
        func_1_1_show_help
        exit 0
    fi
    # Separately, because libargs_key strips only a leading '--': a single-dash
    # -h never matches an option name. Same shape as 2-rebuild.sh.
    case "${1:-}" in
        -h)
            func_1_1_show_help
            exit 0
            ;;
    esac

    func_1_2_check_options "$@"
    func_1_3_init_paths
    func_1_4_init_gitlab_config "$@"
    func_1_5_init_git_config "$@"
    func_1_6_init_publish_config "$@"
    func_1_7_check_deps
    func_1_8_report_config

    func_check_manifest
    func_check_projects

    func_publish

    if [ "${DRY_RUN}" = no ]; then
        func_report_clone
    fi
}

main "$@"
