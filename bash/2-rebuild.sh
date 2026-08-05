#!/bin/bash
set -e

# ============================================================================
# 1_0  Libraries
# ============================================================================

# func_1_0_load_libs: source the shared libraries this script depends on.
#
# utils.sh (libutils_die/libutils_say/libutils_warn), args.sh (option parsing) and gitrepo.sh
# (libgitrepo_is_real_repo, the Step 1 re-run guard) are taken.
#
# gitlab.sh is deliberately NOT sourced. Its functions are written for
# reclaim-one.sh's one-directory-per-invocation model, while Step 3 here drives
# its own batch loop with a shared auth URL; borrowing them would couple two
# scripts whose failure modes differ on purpose. gitrepo.sh is different: the
# state of one ./.git is a fact about git, not about either script's control
# flow, so exactly one definition of "is this already a repository" should
# exist.
#
# First, because everything below calls libutils_die().
#
# BASH_SOURCE rather than $0 so it stays correct when the file is sourced for
# testing, and readlink -f so it survives being invoked through a symlink
# placed on PATH.
func_1_0_load_libs(){
    local libs
    libs="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/libs"

    # utils first: everything else calls libutils_die().
    . "$libs/utils.sh"
    . "$libs/args.sh"
    . "$libs/gitrepo.sh"
    . "$libs/manifest.sh"
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
  git, git-lfs, curl, realpath and find must all be installed. All of them
  are checked before Step 0, so a missing one costs you an error message
  rather than a half-rebuilt tree.

Processing:
  Step 0 scans for dangling .git symlinks once, writing subprojects.txt.
  Then every subproject is taken from nothing to done -- git init, LFS,
  commit, push if --push was given, and finally its manifest line -- before
  the next one is started.

  That ordering is what makes an interrupted run recoverable. The manifest
  is appended to as each subproject finishes, so default.xml.part always
  names exactly the subprojects that are genuinely complete. Re-running the
  same command resumes: finished repositories are detected and skipped with
  their history intact, and the manifest is rebuilt from scratch so no
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
# Single source of truth, handed to libargs_check_known so a misspelled option is
# an error instead of a silent fall back to a default. Without it a typo like
# --gitlab_ur=http://... is ignored, and the run proceeds against no server at
# all while looking healthy. Must be edited together with the 1_7 and 1_8
# readers below.
func_1_2_option_names(){
    echo "gitlab-url gitlab-group gitlab-token" \
         "git-user-name git-user-email branch commit-msg lfs-min-mb" \
         "push help"
}

# ============================================================================
# 1_3  Flag vocabulary
# ============================================================================

# func_1_3_flag_names: print the subset of options that take no value.
#
# libargs_positional needs this to tell `--help /path/to/sdk` (a flag, then the
# positional) apart from `--branch main` (an option, then its value). Without
# it the SDK root is swallowed as the flag's value and the positional silently
# falls back to empty.
func_1_3_flag_names(){
    echo "push help"
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
    libargs_check_known "$(func_1_2_option_names)" "$@"
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

    # The manifest is accumulated here and renamed into place only when the run
    # completes, so an interrupted run leaves a .part naming exactly the
    # subprojects that finished, and default.xml is never a truncated file that
    # looks usable.
    MANIFEST_PART="${MANIFEST_FILE}.part"
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
    sdk_arg=$(libargs_positional 0 "" "$(func_1_3_flag_names)" "$@")

    if [ -z "$sdk_arg" ]; then
        # A usage error is diagnostic output, so it goes to stderr and leaves
        # a piped stdout clean.
        func_1_1_show_help >&2
        exit 1
    fi

    if [ ! -d "$sdk_arg" ]; then
        libutils_die "SDK root does not exist: $sdk_arg"
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
    GITLAB_URL=$(libargs_get gitlab-url "" "$@")
    if [ -z "$GITLAB_URL" ]; then
        libutils_die "missing required option: --gitlab-url (e.g. --gitlab-url=http://gitlab.example.com)"
    fi

    GITLAB_GROUP=$(libargs_get gitlab-group "" "$@")
    if [ -z "$GITLAB_GROUP" ]; then
        libutils_die "missing required option: --gitlab-group (the GitLab group to push into)"
    fi

    # Not required, and not checked here. Steps 0-2 touch no server, and
    # demanding a credential to run them would discourage the local rehearsal
    # that catches a bad subprojects.txt before anything reaches GitLab.
    # func_step3_push_to_remote checks for it at the point of use.
    GITLAB_TOKEN=$(libargs_get gitlab-token "" "$@")
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
# 1_9  Git LFS configuration
# ============================================================================

# func_1_9_init_lfs_config: read the LFS threshold.
#
# $@ -- the caller's raw arguments
#
# Thin on purpose. Reading a command line option is this script's job; deciding
# what makes a threshold valid is git's, so the check is libgitrepo_check_min_mb
# over in libs/gitrepo.sh next to the libgitrepo_find_big arithmetic it protects.
# reclaim-one.sh had already grown its own copy of that same case statement,
# which is the usual sign the rule belongs in the library rather than in each
# caller's parser.
#
# LFS is on by default, with the same 50MB threshold reclaim-one.sh uses. There
# is deliberately no --no-lfs switch: libgitrepo_setup_lfs already reports "not
# needed" and returns 0 when nothing crosses the threshold, so "off" is
# reachable by raising the number. A separate boolean would make one state
# expressible two ways and leave --no-lfs --lfs-min-mb=10 meaning nothing in
# particular.
func_1_9_init_lfs_config(){
    LFS_MIN_MB=$(libargs_get lfs-min-mb "50" "$@")
    libgitrepo_check_min_mb "$LFS_MIN_MB"
}

# ============================================================================
# 1_10  Dependency check
# ============================================================================

# func_1_10_check_deps: die unless every external command this run needs is
# installed.
#
# Checked during initialisation rather than inside the step that first needs
# each command. This script processes dozens of subprojects and Step 1 opens by
# running `rm -rf .git`; discovering at subproject 37 that git-lfs was never
# installed leaves 36 rebuilt repositories and one dead midway, which is a far
# worse position than never having started.
#
# libutils_require_cmd comes from libs/utils.sh (defined there at libutils_require_cmd, sourced by
# func_1_0_load_libs). It dies naming the first missing command. Until now
# nothing in this repository actually called it, which is why a missing
# dependency surfaced as a raw "command not found" mid-run.
#
# The LFS pair is libgitrepo_require_lfs rather than a bare `libutils_require_cmd git-lfs`,
# because a git-lfs binary on PATH whose filters were never installed passes
# `command -v` and then fails at `git lfs track`. That distinction is git
# knowledge, so it lives in the library.
#
# curl is used only by Step 3, but is demanded here too: Step 3 is the stage
# with the most work already sunk behind it, so a missing curl is precisely the
# failure worth catching before Step 0 rather than after Step 2.
func_1_10_check_deps(){
    libutils_require_cmd git curl realpath find
    libgitrepo_require_lfs
}

# ============================================================================
# 1_11  Configuration report
# ============================================================================

# func_1_11_report_config: echo the settled configuration before acting on it.
#
# Printed after everything is validated and before Step 0 destroys anything, so
# the operator gets one chance to notice a wrong group or a wrong SDK root
# while Ctrl-C is still useful.
#
# The token is reported as present/absent, never echoed. It reaches the trace
# via Step 3's URL anyway, but there is no reason to print it twice.
func_1_11_report_config(){
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
        libutils_say "token      : not supplied (Steps 0-2 only)"
    fi
}

# ============================================================================
# 1_12  Per-subproject naming
# ============================================================================

# func_1_12_rel_path: print a subproject's path relative to the SDK root.
#
# $1 -- absolute path to the subproject
#
# Stays in this script rather than moving to libs/: it depends on SDK_ROOT, and
# "where the SDK root is" is knowledge this script has and the libraries
# deliberately do not. libs/gitrepo.sh states that restriction explicitly, and
# libs/manifest.sh takes an already-relative path for the same reason.
func_1_12_rel_path(){
    echo "${1#"${SDK_ROOT}"/}"
}

# func_1_12_repo_name: print the GitLab project name for a subproject.
#
# $1 -- the subproject's path relative to the SDK root
#
# Slashes fold to dashes because GitLab projects live in one flat group, while
# the SDK's directory layout is carried by the manifest's path= instead. That is
# also what keeps external/mpp and kernel/mpp from colliding: they become
# external-mpp and kernel-mpp.
#
# One definition, shared by the manifest line and the push. These were separate
# copies in the old Step 2 and Step 3, so the naming rule had to be changed in
# two places -- and a manifest that disagrees with the pushed repository names
# is a `repo sync` that fails for everyone.
func_1_12_repo_name(){
    echo "$1" | tr '/' '-'
}

# ============================================================================
# 1_13  Push mode
# ============================================================================

# func_1_13_init_push_mode: decide whether this run touches the server.
#
# $@ -- the caller's raw arguments
#
# Off by default, replacing the commented-out call to Step 3 that used to serve
# this purpose. A flag is better than an edit: an operator who has to uncomment
# a line to push has no way to say "not this time" without editing the file
# back, and a file that must be edited between runs cannot be driven from a
# script or a shell history entry.
#
# The token is not required here. That check belongs to func_step3_prepare_auth,
# which runs before the loop when --push is set and is skipped entirely when it
# is not.
func_1_13_init_push_mode(){
    if libargs_is_true push "$@"; then
        DO_PUSH=yes
    else
        DO_PUSH=no
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

# ==================== 阶段 1：单个子工程的本地 git init 提交 ====================

# func_step1_local_init_one: build and commit ONE subproject's repository.
#
# $1 -- absolute path to the subproject
#
# Operates on the directory it is given and returns with the shell inside it.
# The caller owns the loop; this function owns one directory.
#
# Builds unconditionally. The caller tests libgitrepo_is_real_repo first and
# does not call this for a subproject that already has one, so there is no
# "already done" case here and nothing to report but success.
#
# That split is deliberate, and it is what this function used to get wrong.
# While it decided for itself and reported which of the two it had done, the
# caller needed a third answer out of it -- created, skipped, or genuinely
# failed -- and bash carries only two of those in an exit status. Both attempts
# at smuggling the third one out were bugs: an `if` around the call disabled
# `set -e` for everything beneath it, and capturing a status word with $(...)
# swallowed git's own output into the variable. Asking the question at the call
# site instead leaves this function one job and one outcome.
#
# Failures need no handling here. Every git command below runs under the
# caller's `set -e`, so a failing one aborts the run at the point of failure.
func_step1_local_init_one(){
    local abs_path="$1"

    cd "$abs_path"

    rm -rf .git # 删除原来的旧/错软链接
    git init -b "${DEFAULT_BRANCH}"
    git config user.name "${GIT_USER_NAME}"
    git config user.email "${GIT_USER_EMAIL}"

    # MUST precede `git add .`, and the ordering is not cosmetic: a large
    # file that enters history as an ordinary blob can only be moved to LFS
    # afterwards by rewriting history. Track first, add second.
    libgitrepo_setup_lfs "${LFS_MIN_MB}"

    git add .
    git commit -m "${GIT_COMMIT_MSG}"
}

# ==================== 阶段 3：单个子工程的 GitLab 建库并 Push ====================

# func_step3_push_one: create the GitLab project for ONE subproject and push it.
#
# $1 -- absolute path to the subproject
# $2 -- its repository name
#
# Expects AUTH_URL to have been built already by func_step3_prepare_auth, once
# per run rather than once per subproject.
func_step3_push_one(){
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

# func_step3_prepare_auth: build the authenticated push URL, once per run.
#
# Kept out of the loop because it is identical for every subproject, and out of
# func_1_7 because Steps 0-2 have no use for it and no need of a token.
func_step3_prepare_auth(){
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
# The ordering inside the loop body is the design. Each subproject is taken from
# nothing to done -- init, commit, push if asked, manifest line -- before the
# next one is touched. The alternative, which this replaces, was one full pass
# per stage: every repository built, then every manifest line written, then
# every push attempted.
#
# Per-stage passes fail badly. A failure in pass 2 leaves pass 1's work
# undocumented, and a manifest is exactly the document needed to resume. Per
# subproject, a failure leaves everything before it complete and recorded, and
# the manifest .part names precisely how far the run got.
#
# The manifest line is written LAST for each subproject, after its repository
# exists and after its push has succeeded. So a line in the file means that
# subproject is genuinely finished, not merely attempted -- which is what makes
# the .part file trustworthy enough to resume from.
#
# Pushing is inside this loop rather than in a later pass for the same reason:
# a subproject that is committed but not pushed is a half-finished unit of work,
# and keeping the unit whole is what makes the run interruptible at any point.
func_process_all(){
    local created=0 skipped=0 pushed=0 total=0
    local abs_path rel repo_name

    func_step0_scan_subprojects

    echo -e "\n"
    echo ">>> [Manifest] 开始增量写入 ${MANIFEST_PART} ..."
    libmanifest_begin "${MANIFEST_PART}" \
        "${GITLAB_URL}/${GITLAB_GROUP}/" "${GITLAB_URL}/" "${DEFAULT_BRANCH}"

    if [ "${DO_PUSH}" = yes ]; then
        func_step3_prepare_auth
    fi

    while IFS= read -r abs_path; do
        [ -z "$abs_path" ] && continue

        total=$((total + 1))
        rel=$(func_1_12_rel_path "$abs_path")
        repo_name=$(func_1_12_repo_name "$rel")

        echo "=================================================="
        echo "[$total] ${rel}"

        # The guard that makes re-running this script safe. Without it each run
        # rm -rf'd .git and re-inited, discarding every commit made since the
        # last one: new hashes, vendor baseline only, and any fix committed in
        # between gone from history. The files survived, because `git add .`
        # picked them back up from the working tree -- which is what made it
        # quiet. A rebuilt tree looks identical until you ask for the log.
        # Re-running is the normal way to resume, so resuming must not destroy.
        #
        # Asked here rather than inside func_step1_local_init_one so that the
        # function has one outcome instead of three. `if` is safe around this
        # particular call because a subshell'd cd and two tests is a pure
        # query -- nothing here can fail in a way worth aborting for. The build
        # itself, which can, is called bare in the else branch where `set -e`
        # is live. (Bash disables `set -e` inside an `if` condition and for
        # everything it calls, so putting the build there let a subproject whose
        # `git init` had failed carry on and collect a manifest line claiming
        # success -- the dishonest manifest this loop exists to prevent.)
        #
        # The subshell keeps the cd from leaking: the else branch needs to be
        # entered from wherever we started, not from the last subproject.
        if ( cd "$abs_path" && libgitrepo_is_real_repo ); then
            skipped=$((skipped + 1))
            echo "SKIP: 已是 git 仓库，保留其历史"
        else
            func_step1_local_init_one "$abs_path"
            created=$((created + 1))
        fi

        if [ "${DO_PUSH}" = yes ]; then
            func_step3_push_one "$abs_path" "$repo_name"
            pushed=$((pushed + 1))
        fi

        # Last, and only once this subproject's own work has succeeded, so a
        # line in the file always means "done" rather than "attempted".
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
# The func_1_* helpers are numbered in the order this function calls them, so
# the file reads top to bottom in execution order and the numbers stay a
# reliable index. Renumber them if you reorder the calls.
#
# Initialisation is split rather than lumped into one prepare_everything(), so
# that the cheap checks come first and nothing important is settled late:
#
#   1_4  reject unknown options   <- before any state exists
#   1_5  paths and output files   <- Steps 0-3 all depend on these
#   1_6  SDK root                 <- validated before it is used to scan
#   1_7  GitLab config            <- required values, checked one by one
#   1_8  git config               <- ditto
#   1_9  LFS threshold            <- validated before Step 1 consumes it
#   1_10 dependencies             <- everything git/curl/lfs, before any rm -rf
#   1_13 push mode                <- must precede the report, which shows it
#   1_11 report                   <- last chance to Ctrl-C before Step 0
#
# 1_12 is the naming pair, called per subproject from inside the loop rather
# than once during initialisation, which is why it is not in this list.
main() {
    func_1_0_load_libs

    # Handled before anything else, so --help works with no arguments, a
    # nonexistent path, or a machine that has no GitLab access at all. Also
    # before the "Starting..." banner, which would otherwise be a lie.
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

    func_1_4_check_options "$@"
    func_1_5_init_paths
    func_1_6_init_sdk_root "$@"
    func_1_7_init_gitlab_config "$@"
    func_1_8_init_git_config "$@"
    func_1_9_init_lfs_config "$@"
    func_1_10_check_deps
    func_1_13_init_push_mode "$@"
    func_1_11_report_config

    func_process_all
}

main "$@"
