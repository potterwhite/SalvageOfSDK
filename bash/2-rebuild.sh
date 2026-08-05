#!/bin/bash
set -e

# ============================================================================
# 1_0  Libraries
# ============================================================================

# func_1_0_load_libs: source the shared libraries this script depends on.
#
# utils.sh (die/say/warn), args.sh (option parsing) and gitrepo.sh
# (gitrepo_is_real_repo, the Step 1 re-run guard) are taken.
#
# gitlab.sh is deliberately NOT sourced. Its functions are written for
# reclaim-one.sh's one-directory-per-invocation model, while Step 3 here drives
# its own batch loop with a shared auth URL; borrowing them would couple two
# scripts whose failure modes differ on purpose. gitrepo.sh is different: the
# state of one ./.git is a fact about git, not about either script's control
# flow, so exactly one definition of "is this already a repository" should
# exist.
#
# First, because everything below calls die().
#
# BASH_SOURCE rather than $0 so it stays correct when the file is sourced for
# testing, and readlink -f so it survives being invoked through a symlink
# placed on PATH.
func_1_0_load_libs(){
    local libs
    libs="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/libs"

    # utils first: everything else calls die().
    . "$libs/utils.sh"
    . "$libs/args.sh"
    . "$libs/gitrepo.sh"
}

# ============================================================================
# 1_1  Help
# ============================================================================

# func_1_1_show_help: print the usage text.
#
# A function rather than an inline echo because it has two call sites: the
# operator asking for -h, and the argument check rejecting a bad invocation.
# Two copies would drift, and help text that contradicts the script is worse
# than none at all.
#
# Unquoted <<EOF so ${0##*/} expands to the real script name. Consequence:
# nothing in the body may carry a bare '$', or it silently expands to empty --
# which is why the one example below escapes its own.
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

  These four have no defaults, on purpose. A baked-in server address or
  identity is exactly the kind of default that yields a wrong result looking
  like a right one -- an SDK pushed to whichever host the last operator
  happened to use. Being asked for them once beats finding out afterwards.

Optional:
  --gitlab-token=TOKEN  Personal Access Token; needs the api scope. Read by
                        Step 3 only, so Steps 0-2 run without one.
  --branch=BRANCH       Default branch name.      default main
  --commit-msg=MSG      Initial commit message.
                        default "Initial commit: Reconstruct SDK baseline"
  -h, --help            Print this text and exit. Checks nothing, touches
                        nothing.

  Underscores and hyphens are interchangeable, so --gitlab_url and
  --gitlab-url name the same option. Both --key=value and --key value are
  accepted; prefer --key=value when the value could start with a dash.

Stages:
  Step 0  Scan for dangling .git symlinks; write them to subprojects.txt.
          Skipped when that file already exists, so a hand-corrected list
          is never overwritten.
  Step 1  git init plus an initial commit in each subproject. Local only.
  Step 2  Generate default.xml (the repo manifest) from subprojects.txt.
  Step 3  Create the GitLab projects and push. Commented out in main() by
          default; uncomment when you mean it.

Outputs (written to the current working directory, not the SDK root):
  subprojects.txt       Subproject paths, one per line.
  default.xml           The repo manifest.

Cautions:
  * Step 1 runs rm -rf .git in every subproject. The original symlinks are
    not recoverable. Back up first, or run Step 0 alone and inspect
    subprojects.txt before going further.
  * Step 3 pushes with -f, overwriting the matching remote branch.
  * This script runs under 'set -x', so a token passed on the command line
    appears both in the trace and in your shell history. Prefer
    --gitlab-token="\$(cat ~/.gitlab-token)" on a shared machine.
EOF
}

# ============================================================================
# 1_2  Option vocabulary
# ============================================================================

# func_1_2_option_names: print every option this script accepts.
#
# Single source of truth, handed to args_check_known so a misspelled option is
# an error instead of a silent fall back to a default. Without it a typo like
# --gitlab_ur=http://... is ignored, and the run proceeds against no server at
# all while looking healthy. Must be edited together with the 1_7 and 1_8
# readers below.
func_1_2_option_names(){
    echo "gitlab-url gitlab-group gitlab-token" \
         "git-user-name git-user-email branch commit-msg help"
}

# ============================================================================
# 1_3  Flag vocabulary
# ============================================================================

# func_1_3_flag_names: print the subset of options that take no value.
#
# args_positional needs this to tell `--help /path/to/sdk` (a flag, then the
# positional) apart from `--branch main` (an option, then its value). Without
# it the SDK root is swallowed as the flag's value and the positional silently
# falls back to empty.
func_1_3_flag_names(){
    echo "help"
}

# ============================================================================
# 1_4  Reject unknown options
# ============================================================================

# func_1_4_check_options: die if an option was passed that we do not accept.
#
# $@ -- the caller's raw arguments
#
# Runs before anything is read or initialised, so a mistyped option costs the
# operator an error message rather than a half-rebuilt SDK.
func_1_4_check_options(){
    args_check_known "$(func_1_2_option_names)" "$@"
}

# ============================================================================
# 1_5  Paths and output files
# ============================================================================

# func_1_5_init_paths: settle where this script lives and where it writes.
#
# Deliberately early. Steps 1 and 3 cd back to BASH_SCRIPT_DIR when their loop
# finishes, and Steps 0/2 write to the two files named here; leaving any of
# them until after option parsing would mean a run that fails on a bad option
# has already half-decided where its output goes.
#
# RUN_DIR is the invocation directory, not the script directory, so the
# generated files land where the operator is standing.
func_1_5_init_paths(){
    BASH_SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
    BASH_SCRIPT_DIR="$(dirname "${BASH_SCRIPT_PATH}")"
    RUN_DIR="$(pwd -P)"

    MANIFEST_FILE="${RUN_DIR}/default.xml"
    SUBPROJECTS_FILE="${RUN_DIR}/subprojects.txt"
}

# ============================================================================
# 1_6  SDK root
# ============================================================================

# func_1_6_init_sdk_root: resolve the one positional argument.
#
# $@ -- the caller's raw arguments
#
# No default. Guessing '.' would let a run started from the wrong directory
# scan and rewrite an unrelated tree, which is the single most expensive
# mistake available in this script.
func_1_6_init_sdk_root(){
    local sdk_arg
    sdk_arg=$(args_positional 0 "" "$(func_1_3_flag_names)" "$@")

    if [ -z "$sdk_arg" ]; then
        # A usage error is diagnostic output, so it goes to stderr and leaves
        # a piped stdout clean.
        func_1_1_show_help >&2
        exit 1
    fi

    if [ ! -d "$sdk_arg" ]; then
        die "SDK root does not exist: $sdk_arg"
    fi

    SDK_ROOT="$(realpath "$sdk_arg")"
}

# ============================================================================
# 1_7  GitLab server configuration
# ============================================================================

# func_1_7_init_gitlab_config: read the GitLab options, one at a time.
#
# $@ -- the caller's raw arguments
#
# Each value is read and then checked on its own line, and each complaint names
# the option the operator actually typed plus an example. That is worth more
# than a single combined "missing options: ..." message, because the example is
# the part that tells them what shape the value takes.
func_1_7_init_gitlab_config(){
    GITLAB_URL=$(args_get gitlab-url "" "$@")
    if [ -z "$GITLAB_URL" ]; then
        die "missing required option: --gitlab-url (e.g. --gitlab-url=http://gitlab.example.com)"
    fi

    GITLAB_GROUP=$(args_get gitlab-group "" "$@")
    if [ -z "$GITLAB_GROUP" ]; then
        die "missing required option: --gitlab-group (the GitLab group to push into)"
    fi

    # Not required, and not checked here. Steps 0-2 touch no server, and
    # demanding a credential to run them would discourage the local rehearsal
    # that catches a bad subprojects.txt before anything reaches GitLab.
    # func_step3_push_to_remote checks for it at the point of use.
    GITLAB_TOKEN=$(args_get gitlab-token "" "$@")
}

# ============================================================================
# 1_8  Git commit configuration
# ============================================================================

# func_1_8_init_git_config: read the git options, one at a time.
#
# $@ -- the caller's raw arguments
#
# --branch and --commit-msg carry defaults because both are conventions rather
# than facts about a particular deployment: getting either wrong is visible and
# cheap to correct. The identity is neither, so it is required.
func_1_8_init_git_config(){
    GIT_USER_NAME=$(args_get git-user-name "" "$@")
    if [ -z "$GIT_USER_NAME" ]; then
        die "missing required option: --git-user-name (value for git config user.name)"
    fi

    GIT_USER_EMAIL=$(args_get git-user-email "" "$@")
    if [ -z "$GIT_USER_EMAIL" ]; then
        die "missing required option: --git-user-email (value for git config user.email)"
    fi

    DEFAULT_BRANCH=$(args_get branch "main" "$@")
    if [ -z "$DEFAULT_BRANCH" ]; then
        die "--branch was given an empty value"
    fi

    GIT_COMMIT_MSG=$(args_get commit-msg "Initial commit: Reconstruct SDK baseline" "$@")
    if [ -z "$GIT_COMMIT_MSG" ]; then
        die "--commit-msg was given an empty value"
    fi
}

# ============================================================================
# 1_9  Configuration report
# ============================================================================

# func_1_9_report_config: echo the settled configuration before acting on it.
#
# Printed after everything is validated and before Step 0 destroys anything, so
# the operator gets one chance to notice a wrong group or a wrong SDK root
# while Ctrl-C is still useful.
#
# The token is reported as present/absent, never echoed. It reaches the trace
# via Step 3's URL anyway, but there is no reason to print it twice.
func_1_9_report_config(){
    say "SDK root   : ${SDK_ROOT}"
    say "GitLab     : ${GITLAB_URL}"
    say "group      : ${GITLAB_GROUP}"
    say "branch     : ${DEFAULT_BRANCH}"
    say "committer  : ${GIT_USER_NAME} <${GIT_USER_EMAIL}>"
    say "manifest   : ${MANIFEST_FILE}"
    say "subprojects: ${SUBPROJECTS_FILE}"

    if [ -n "${GITLAB_TOKEN}" ]; then
        say "token      : supplied"
    else
        say "token      : not supplied (Steps 0-2 only)"
    fi
}

# ==================== 阶段 0：扫描子工程 (仅需执行一次) ====================
func_step0_scan_subprojects(){
    echo -e "\n"
    echo ">>> [Step 0] 正在扫描所有的子节点软链接..."
    if [ ! -f "$SUBPROJECTS_FILE" ]; then
        # 只有第一次不存在时才扫描，避免覆盖
        # find . -name .git -type l | sed 's|/\.git||' | sed 's|^\./||' > "$SUBPROJECTS_FILE"
        find "${SDK_ROOT}" -name .git -type l -exec bash -c 'realpath "$(dirname "{}")"' \;  > "$SUBPROJECTS_FILE"
        echo "已生成 $SUBPROJECTS_FILE，共找到 $(wc -l < $SUBPROJECTS_FILE) 个子工程。"
    else
        echo "$SUBPROJECTS_FILE 已存在，跳过扫描，直接复用。"
    fi
}

# ==================== 阶段 1：纯本地 git init 提交 ====================
func_step1_local_init_all(){
    echo -e "\n"
    echo ">>> [Step 1] 开始本地初始化 git 仓库并提交..."

    local created=0 skipped=0

    while IFS= read -r abs_path; do
        [ -z "$abs_path" ] && continue

        # abs_path="${SDK_ROOT}/${abs_path}"
        cd "$abs_path"

        # The guard that makes re-running this script safe.
        #
        # Without it the loop unconditionally rm -rf'd .git and re-inited, so
        # re-running to reach a Step 3 that was skipped the first time discarded
        # every commit made since: new hashes, vendor baseline only, and any fix
        # committed in between gone from history. The files survived, because
        # `git add .` picked them back up from the working tree -- which is what
        # made it quiet. A rebuilt tree looks identical until you ask for the log.
        #
        # Re-running is the normal way to resume this script, so resuming must
        # not be destructive.
        if gitrepo_is_real_repo; then
            echo "SKIP: 已是 git 仓库，保留其历史: $abs_path"
            skipped=$((skipped + 1))
            continue
        fi

        echo "Processing local git: $abs_path"

        rm -rf .git # 删除原来的旧/错软链接
        git init -b "${DEFAULT_BRANCH}"
        git config user.name "${GIT_USER_NAME}"
        git config user.email "${GIT_USER_EMAIL}"
        git add .
        git commit -m "${GIT_COMMIT_MSG}"
        created=$((created + 1))

    done < "$SUBPROJECTS_FILE"

    cd "${BASH_SCRIPT_DIR}"
    echo ">>> [Step 1] 完成：新建 ${created} 个，跳过 ${skipped} 个已有仓库。"
}

# ==================== 阶段 2：生成 Manifest (default.xml) ====================
func_step2_create_manifest(){
    echo -e "\n"
    echo ">>> [Step 2] 开始生成 $MANIFEST_FILE ..."

    cat <<EOF > "$MANIFEST_FILE"
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remote name="origin" fetch="${GITLAB_URL}/${GITLAB_GROUP}/" review="${GITLAB_URL}/" />
  <default revision="${DEFAULT_BRANCH}" remote="origin" sync-j="4" />

EOF

    while IFS= read -r abs_path; do
        [ -z "$abs_path" ] && continue

        rel="${abs_path#$SDK_ROOT/}"
        repo_name=$(echo "$rel" | tr '/' '-')

        # 注意：这里必须是相对路径 rel_path！
        echo "  <project path=\"${rel}\" name=\"${repo_name}.git\" />" >> "$MANIFEST_FILE"
    done < "$SUBPROJECTS_FILE"

    echo "</manifest>" >> "$MANIFEST_FILE"
    echo ">>> [Step 2] $MANIFEST_FILE 生成完毕！"
}

# ==================== 阶段 3：GitLab 建库并 Push ====================
func_step3_push_to_remote(){
    echo -e "\n"
    echo ">>> [Step 3] 开始创建远程仓库并 Push..."

    # Checked at the point of use rather than in 1_7, so that Steps 0-2 -- which
    # touch no server -- need no credential at all.
    if [ -z "${GITLAB_TOKEN}" ]; then
        die "Step 3 needs --gitlab-token (api scope)"
    fi

    AUTH_URL=$(echo "${GITLAB_URL}" | sed -E "s#(https?://)#\1oauth2:${GITLAB_TOKEN}@#")

    while IFS= read -r abs_path; do
        [ -z "$abs_path" ] && continue

        rel="${abs_path#$SDK_ROOT/}"
        repo_name=$(echo "$rel" | tr '/' '-')

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

        # 可选：按回车单步调试 Push
        # read -p "Press Enter to continue to next push..."

    done < "$SUBPROJECTS_FILE"

    cd "${BASH_SCRIPT_DIR}"
    echo ">>> [Step 3] 全部子工程已成功 Push 到 GitLab！"
}

# ============================================================================
# main
# ============================================================================

# main: the only entry point.
#
# The func_1_* helpers are numbered in the order this function calls them, so
# the file reads top to bottom in execution order and the numbers stay a
# reliable index. Renumber them if you reorder the calls.
#
# Initialisation is split rather than lumped into one prepare_everything(), so
# that the cheap checks come first and nothing important is settled late:
#
#   1_4 reject unknown options   <- before any state exists
#   1_5 paths and output files   <- Steps 0-3 all depend on these
#   1_6 SDK root                 <- validated before it is used to scan
#   1_7 GitLab config            <- required values, checked one by one
#   1_8 git config               <- ditto
#   1_9 report                   <- last chance to Ctrl-C before Step 0
main() {
    func_1_0_load_libs

    # Handled before anything else, so --help works with no arguments, a
    # nonexistent path, or a machine that has no GitLab access at all. Also
    # before the "Starting..." banner, which would otherwise be a lie.
    if args_is_true help "$@"; then
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

    func_1_4_check_options "$@"
    func_1_5_init_paths
    func_1_6_init_sdk_root "$@"
    func_1_7_init_gitlab_config "$@"
    func_1_8_init_git_config "$@"
    func_1_9_report_config

    func_step0_scan_subprojects
    func_step1_local_init_all
    func_step2_create_manifest
    #func_step3_push_to_remote
}

main "$@"
