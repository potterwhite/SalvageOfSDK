#!/bin/bash
set -e

# ============================================================================
# 1_0  Libraries
# ============================================================================

# func_1_0_load_libs: source the shared libraries.
#
# gitlab.sh is sourced only for its URL builders (libgitlab_ssh_url and the
# libgitlab_host it calls). Its project/push functions are not used here: they
# assume one-directory-per-invocation, while the loop below drives a batch with
# a shared auth URL.
#
# BASH_SOURCE rather than $0, and readlink -f, so this works when the file is
# sourced for testing or invoked through a symlink on PATH.
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
# nothing in the body may carry a bare '$' or it silently expands to empty,
# which is why the example below escapes its own.
func_1_1_show_help(){
    # stdout, so `2-rebuild.sh -h | less` works. The usage-error path
    # redirects this to stderr instead.
    cat <<EOF
Usage: ${0##*/} --gitlab-url=URL --gitlab-group=GROUP \\
           --git-user-name=NAME --git-user-email=ADDR \\
           [options] <path_to_sdk_root>
       ${0##*/} -h | --help

Reassemble an SDK whose .repo metadata was stripped back into a set of git
repositories.

Arguments:
  <path_to_sdk_root>    SDK root. Must already exist.

Required options:
  --gitlab-url=URL      GitLab base address, e.g. http://gitlab.example.com
  --gitlab-group=GROUP  Group name on GitLab.
  --git-user-name=NAME  Value for git config user.name.
  --git-user-email=ADDR Value for git config user.email.

  These four have no defaults on purpose. A baked-in server address or
  identity is the kind of default that pushes an SDK to the wrong host and
  reports success.

Optional:
  --gitlab-token=TOKEN  Personal Access Token; needs the api scope. Only
                        needed with --push.
  --branch=BRANCH       Default branch name.      default main
  --commit-msg=MSG      Initial commit message.
                        default "Initial commit: Reconstruct SDK baseline"
  --lfs-min-mb=N        Files at or above this size go to Git LFS.
                        default 50. Raise it to disable LFS in practice;
                        there is no separate off switch.
  --push                Also create the GitLab projects and push. Off by
                        default, so a run without it is entirely local.
                        Requires --gitlab-token.
  -h, --help            Print this text and exit. Checks nothing, touches
                        nothing.

  Underscores and hyphens are interchangeable, so --gitlab_url and
  --gitlab-url name the same option. Both --key=value and --key value are
  accepted; prefer --key=value when the value could start with a dash.

Requirements:
  git, git-lfs, curl, realpath and find must all be installed. All are
  checked before anything is modified.

Processing:
  Dangling .git symlinks are scanned once into subprojects.txt. Then each
  subproject is taken from nothing to done -- git init, LFS, commit, push if
  --push was given, and finally its manifest line -- before the next is
  started.

  That ordering is what makes an interrupted run recoverable:
  default.xml.part always names exactly the subprojects that are complete.
  Re-running the same command resumes -- finished repositories are skipped
  with their history intact, and the manifest is rebuilt from scratch so no
  entry can appear twice.

Outputs (written to the current working directory, not the SDK root):
  subprojects.txt       Subproject paths, one per line.
  default.xml           The repo manifest. Written only on completion.
  default.xml.part      The manifest under construction. Left behind by an
                        interrupted run, and it tells you how far it got.

Cautions:
  * The first run replaces each dangling .git symlink with a real
    repository, and the symlinks are not recoverable. Back up first, or
    inspect subprojects.txt after a scan and before going further. A
    subproject that already holds a real repository is never touched.
  * --push pushes with -f, overwriting the matching remote branch.
  * A token passed on the command line lands in your shell history. Prefer
    --gitlab-token="\$(cat ~/.gitlab-token)" on a shared machine.
EOF
}

# ============================================================================
# 1_2  Option vocabulary
# ============================================================================

# func_1_2_check_options: define the accepted options and reject anything else.
#
# $@ -- the caller's raw arguments
#
# One source of truth for both lists, set before any other option is read.
# Without the whitelist a typo like --gitlab_ur=http://... is ignored and the
# run proceeds against no server while looking healthy.
#
# FLAG_NAMES is the subset taking no value. libargs_positional needs it to tell
# `--help /path/to/sdk` (flag, then positional) from `--branch main` (option,
# then its value); without it the SDK root is swallowed as a flag's value.
#
# Edit these together with the readers in 1_5 and 1_6.
func_1_2_check_options(){
    OPTION_NAMES="gitlab-url gitlab-group gitlab-token \
git-user-name git-user-email branch commit-msg lfs-min-mb push help"
    FLAG_NAMES="push help"

    libargs_check_known "$OPTION_NAMES" "$@"
}

# ============================================================================
# 1_3  Paths and output files
# ============================================================================

# func_1_3_init_paths: settle where this script lives and where it writes.
#
# Early, because the loop cds back to BASH_SCRIPT_DIR when it finishes and both
# output files are named here.
#
# RUN_DIR is the invocation directory, not the script directory, so generated
# files land where the operator is standing.
func_1_3_init_paths(){
    BASH_SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
    BASH_SCRIPT_DIR="$(dirname "${BASH_SCRIPT_PATH}")"
    RUN_DIR="$(pwd -P)"

    MANIFEST_FILE="${RUN_DIR}/default.xml"

    # Accumulated here and renamed into place only on completion, so default.xml
    # is never a truncated file that looks usable.
    MANIFEST_PART="${MANIFEST_FILE}.part"
    SUBPROJECTS_FILE="${RUN_DIR}/subprojects.txt"
}

# ============================================================================
# 1_4  SDK root
# ============================================================================

# func_1_4_init_sdk_root: resolve the one positional argument.
#
# $@ -- the caller's raw arguments
#
# No default. Guessing '.' would let a run started from the wrong directory
# scan and rewrite an unrelated tree.
func_1_4_init_sdk_root(){
    local sdk_arg
    sdk_arg=$(libargs_positional 0 "" "$FLAG_NAMES" "$@")

    if [ -z "$sdk_arg" ]; then
        # Usage errors are diagnostic output, so stderr; a piped stdout stays clean.
        func_1_1_show_help >&2
        exit 1
    fi

    if [ ! -d "$sdk_arg" ]; then
        libutils_die "SDK root does not exist: $sdk_arg"
    fi

    SDK_ROOT="$(realpath "$sdk_arg")"
}

# ============================================================================
# 1_5  GitLab server configuration
# ============================================================================

# func_1_5_init_gitlab_config: read the GitLab options.
#
# $@ -- the caller's raw arguments
#
# Each complaint names the option as typed plus an example, because the example
# is the part that says what shape the value takes.
func_1_5_init_gitlab_config(){
    GITLAB_URL=$(libargs_get gitlab-url "" "$@")
    if [ -z "$GITLAB_URL" ]; then
        libutils_die "missing required option: --gitlab-url (e.g. --gitlab-url=http://gitlab.example.com)"
    fi

    GITLAB_GROUP=$(libargs_get gitlab-group "" "$@")
    if [ -z "$GITLAB_GROUP" ]; then
        libutils_die "missing required option: --gitlab-group (the GitLab group to push into)"
    fi

    # Not required, and not checked here: a local run touches no server, and
    # demanding a credential for it would discourage the local rehearsal that
    # catches a bad subprojects.txt before anything reaches GitLab.
    # func_prepare_auth checks for it at the point of use.
    GITLAB_TOKEN=$(libargs_get gitlab-token "" "$@")
}

# ============================================================================
# 1_6  Git commit configuration
# ============================================================================

# func_1_6_init_git_config: read the git options.
#
# $@ -- the caller's raw arguments
#
# --branch and --commit-msg carry defaults because both are conventions rather
# than facts about a deployment: getting either wrong is visible and cheap to
# correct. The identity is neither, so it is required.
func_1_6_init_git_config(){
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

    GIT_COMMIT_MSG=$(libargs_get commit-msg "Initial commit: Reconstruct SDK baseline" "$@")
    if [ -z "$GIT_COMMIT_MSG" ]; then
        libutils_die "--commit-msg was given an empty value"
    fi
}

# ============================================================================
# 1_7  Git LFS configuration
# ============================================================================

# func_1_7_init_lfs_config: read the LFS threshold.
#
# $@ -- the caller's raw arguments
#
# Reading the option is this script's job; what makes a threshold valid is
# git's, so the check lives beside the arithmetic it protects in gitrepo.sh.
func_1_7_init_lfs_config(){
    LFS_MIN_MB=$(libargs_get lfs-min-mb "50" "$@")
    libgitrepo_check_min_mb "$LFS_MIN_MB"
}

# ============================================================================
# 1_8  Dependency check
# ============================================================================

# func_1_8_check_deps: die unless every external command this run needs exists.
#
# Checked up front rather than at first use. This script processes dozens of
# subprojects and each one opens with `rm -rf .git`; discovering at subproject
# 37 that git-lfs was never installed leaves 36 rebuilt repositories and one
# dead midway. curl is demanded too even though only --push uses it, for the
# same reason.
#
# libgitrepo_require_lfs rather than a bare libutils_require_cmd git-lfs: a
# git-lfs binary whose filters were never installed passes `command -v` and
# then fails at `git lfs track`.
func_1_8_check_deps(){
    libutils_require_cmd git curl realpath find
    libgitrepo_require_lfs
}

# ============================================================================
# 1_9  Push mode
# ============================================================================

# func_1_9_init_push_mode: decide whether this run touches the server.
#
# $@ -- the caller's raw arguments
#
# The token is not required here; func_prepare_auth checks it before the loop
# when --push is set, and is skipped entirely when it is not.
func_1_9_init_push_mode(){
    if libargs_is_true push "$@"; then
        DO_PUSH=yes
    else
        DO_PUSH=no
    fi
}

# ============================================================================
# 1_10  Configuration report
# ============================================================================

# func_1_10_report_config: echo the settled configuration before acting on it.
#
# After validation and before anything is destroyed, so the operator gets one
# chance to notice a wrong group or SDK root while Ctrl-C is still useful.
#
# The token is reported as present/absent, never echoed.
func_1_10_report_config(){
    libutils_say "SDK root   : ${SDK_ROOT}"
    libutils_say "GitLab     : ${GITLAB_URL}"
    libutils_say "group      : ${GITLAB_GROUP}"
    libutils_say "branch     : ${DEFAULT_BRANCH}"
    libutils_say "committer  : ${GIT_USER_NAME} <${GIT_USER_EMAIL}>"
    libutils_say "LFS        : files >= ${LFS_MIN_MB}MB"
    libutils_say "manifest   : ${MANIFEST_FILE}"
    libutils_say "subprojects: ${SUBPROJECTS_FILE}"

    if [ "${DO_PUSH}" = yes ]; then
        libutils_say "push       : yes (创建远程仓库并 push -f)"
    else
        libutils_say "push       : no (仅本地；稍后加 --push 重跑)"
    fi

    if [ -n "${GITLAB_TOKEN}" ]; then
        libutils_say "token      : supplied"
    else
        libutils_say "token      : not supplied (local only)"
    fi
}

# ============================================================================
# Per-subproject naming
# ============================================================================

# Not func_1_*: these are called per subproject from inside the loop, not once
# from main(). They stay in this script rather than moving to libs/ because they
# depend on SDK_ROOT, which the libraries deliberately do not know about.

# func_rel_path: print a subproject's path relative to the SDK root.
#
# $1 -- absolute path to the subproject
func_rel_path(){
    echo "${1#"${SDK_ROOT}"/}"
}

# func_repo_name: print the GitLab project name for a subproject.
#
# $1 -- the subproject's path relative to the SDK root
#
# Slashes fold to dashes because GitLab projects live in one flat group, while
# the directory layout is carried by the manifest's path= instead. This is also
# what keeps external/mpp and kernel/mpp from colliding: they become
# external-mpp and kernel-mpp.
#
# One definition, shared by the manifest line and the push -- a manifest that
# disagrees with the pushed repository names is a `repo sync` that fails for
# everyone.
func_repo_name(){
    echo "$1" | tr '/' '-'
}

# ============================================================================
# Work units
# ============================================================================

# func_scan_subprojects: find the dangling .git symlinks, once per run.
#
# Skipped when subprojects.txt already exists, so a hand-corrected list is
# never overwritten.
func_scan_subprojects(){
    echo -e "\n"
    echo ">>> [Scan] 正在扫描所有的子节点软链接..."
    if [ ! -f "$SUBPROJECTS_FILE" ]; then
        find "${SDK_ROOT}" -name .git -type l -exec bash -c 'realpath "$(dirname "{}")"' \;  > "$SUBPROJECTS_FILE"
        echo "已生成 $SUBPROJECTS_FILE，共找到 $(wc -l < $SUBPROJECTS_FILE) 个子工程。"
    else
        echo "$SUBPROJECTS_FILE 已存在，跳过扫描，直接复用。"
    fi
}

# func_init_one: build and commit ONE subproject's repository.
#
# $1 -- absolute path to the subproject
#
# Returns with the shell inside that directory. Builds unconditionally -- the
# caller checks for an existing repository first -- so success is its only
# outcome. Every git command runs under `set -e`, so a failure aborts the run
# where it happened and needs no handling here.
func_init_one(){
    local abs_path="$1"

    cd "$abs_path"

    rm -rf .git # 删除原来的旧/错软链接
    git init -b "${DEFAULT_BRANCH}"
    git config user.name "${GIT_USER_NAME}"
    git config user.email "${GIT_USER_EMAIL}"

    # MUST precede `git add .`, and the ordering is not cosmetic: a large file
    # that enters history as an ordinary blob can only be moved to LFS
    # afterwards by rewriting history. Track first, add second.
    libgitrepo_setup_lfs "${LFS_MIN_MB}"

    git add .
    git commit -m "${GIT_COMMIT_MSG}"
}

# func_push_one: create the GitLab project for ONE subproject and push it.
#
# $1 -- absolute path to the subproject
# $2 -- its repository name
#
# Expects AUTH_URL from func_prepare_auth.
func_push_one(){
    local abs_path="$1" repo_name="$2"

    echo "=================================================="
    echo "Pushing: $abs_path -> Remote: $repo_name"
    echo "=================================================="

    # 1. API 建库
    curl --silent --request POST "${GITLAB_URL}/api/v4/projects" \
        --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        --data "name=${repo_name}&path=${repo_name}&namespace_id=$(curl --silent --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" "${GITLAB_URL}/api/v4/groups/${GITLAB_GROUP}" | grep -o '"id":[0-9]*' | head -1 | awk -F: '{print $2}')&visibility=private" > /dev/null || true

    # 2. Push 代码
    cd "$abs_path"
    git remote remove origin 2>/dev/null || true
    git remote add origin "${AUTH_URL}/${GITLAB_GROUP}/${repo_name}.git"
    git push -u origin "${DEFAULT_BRANCH}" -f
}

# func_prepare_auth: build the authenticated push URL, once per run.
func_prepare_auth(){
    if [ -z "${GITLAB_TOKEN}" ]; then
        libutils_die "--push needs --gitlab-token (api scope)"
    fi

    AUTH_URL=$(echo "${GITLAB_URL}" | sed -E "s#(https?://)#\1oauth2:${GITLAB_TOKEN}@#")
}

# ============================================================================
# The one loop
# ============================================================================

# func_process_all: walk subprojects.txt once, finishing each entry completely.
#
# The ordering inside the loop body is the design. Each subproject goes from
# nothing to done -- init, commit, push if asked, manifest line -- before the
# next is touched, so a failure leaves everything before it complete and
# recorded, and the .part file names precisely how far the run got.
#
# The manifest line is written LAST, after the repository exists and its push
# has succeeded, so a line in the file means finished rather than attempted.
# Pushing is inside the loop for the same reason: a subproject committed but not
# pushed is half a unit of work, and keeping the unit whole is what makes the
# run interruptible at any point.
func_process_all(){
    local created=0 skipped=0 pushed=0 total=0
    local abs_path rel repo_name

    func_scan_subprojects

    echo -e "\n"
    echo ">>> [Manifest] 开始增量写入 ${MANIFEST_PART} ..."

    # The manifest advertises SSH, not the HTTP URL we push over. Pushing is
    # unattended and uses a PAT; fetching is done by colleagues, and `repo sync`
    # runs its fetches in parallel with interactive prompting disabled, so an
    # HTTP URL with no stored credential fails outright instead of asking.
    libmanifest_begin "${MANIFEST_PART}" \
        "$(libgitlab_ssh_base "${GITLAB_URL}" "${GITLAB_GROUP}")" \
        "${DEFAULT_BRANCH}"

    if [ "${DO_PUSH}" = yes ]; then
        func_prepare_auth
    fi

    while IFS= read -r abs_path; do
        [ -z "$abs_path" ] && continue

        total=$((total + 1))
        rel=$(func_rel_path "$abs_path")
        repo_name=$(func_repo_name "$rel")

        echo "=================================================="
        echo "[$total] ${rel}"

        # Re-run safety: a subproject that already holds a real repository keeps
        # its history untouched. Re-running is the normal way to resume, so
        # resuming must not be destructive.
        #
        # The test is here rather than inside func_init_one so that function has
        # a single outcome. `if` is safe around a subshell'd cd plus two tests --
        # nothing in it can fail in a way worth aborting for -- while the build,
        # which can, is called bare in the else branch where `set -e` still
        # applies. Bash disables `set -e` inside an `if` condition and
        # everything beneath it, so a build placed there would let a failed
        # `git init` fall through and collect a manifest line claiming success.
        #
        # The subshell also keeps the cd from leaking into the else branch.
        if ( cd "$abs_path" && libgitrepo_is_real_repo ); then
            skipped=$((skipped + 1))
            echo "SKIP: 已是 git 仓库，保留其历史"
        else
            func_init_one "$abs_path"
            created=$((created + 1))
        fi

        if [ "${DO_PUSH}" = yes ]; then
            func_push_one "$abs_path" "$repo_name"
            pushed=$((pushed + 1))
        fi

        libmanifest_append "${MANIFEST_PART}" "$rel" "$repo_name"

    done < "$SUBPROJECTS_FILE"

    cd "${BASH_SCRIPT_DIR}"
    libmanifest_finish "${MANIFEST_PART}" "${MANIFEST_FILE}"
    echo ">>> [Manifest] ${MANIFEST_FILE} 生成完毕，共 $(libmanifest_count "${MANIFEST_FILE}") 个 project。"

    echo -e "\n"
    echo ">>> 全部完成：共 ${total} 个子工程，新建 ${created} 个，跳过 ${skipped} 个已有仓库。"
    if [ "${DO_PUSH}" = yes ]; then
        echo ">>> 已 Push ${pushed} 个到 GitLab。"
    else
        echo ">>> 未 Push（未指定 --push）。稍后加上 --push 重跑即可，已有仓库的历史不会被破坏。"
    fi
}

# ============================================================================
# main
# ============================================================================

# main: the only entry point.
#
# The func_1_* helpers are numbered in the order called below, so the file reads
# top to bottom in execution order. Renumber them if you reorder the calls.
# Initialisation is split rather than lumped together so the cheap checks come
# first and nothing important is settled late -- notably 1_8, which must run
# before the first `rm -rf .git`.
main() {
    func_1_0_load_libs

    # Before anything else, so --help works with no arguments, a nonexistent
    # path, or no GitLab access at all -- and before the banner, which would
    # otherwise be a lie.
    if libargs_is_true help "$@"; then
        func_1_1_show_help
        exit 0
    fi
    case "${1:-}" in
        -h)
            func_1_1_show_help
            exit 0
            ;;
    esac

    echo "Starting the rebuild process..."

    func_1_2_check_options "$@"
    func_1_3_init_paths
    func_1_4_init_sdk_root "$@"
    func_1_5_init_gitlab_config "$@"
    func_1_6_init_git_config "$@"
    func_1_7_init_lfs_config "$@"
    func_1_8_check_deps
    func_1_9_init_push_mode "$@"
    func_1_10_report_config

    func_process_all
}

main "$@"
