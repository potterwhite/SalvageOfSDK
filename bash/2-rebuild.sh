#!/bin/bash
set -ex

# ==================== Help ====================
# func_1_1_show_help: print the usage text.
#
# A function rather than an inline echo because it has two call sites: the
# operator asking for -h, and the argument check rejecting a bad invocation.
# Two copies would drift, and help text that contradicts the script is worse
# than none at all.
#
# Unquoted <<EOF so ${0##*/} expands to the real script name. Consequence:
# nothing in the body may carry a bare '$', or it silently expands to empty --
# which is why the configuration variables below are named without one.
func_1_1_show_help(){
    # stdout, so `2-rebuild.sh -h | less` works. The usage-error path
    # redirects this to stderr instead.
    cat <<EOF
Usage: ${0##*/} <path_to_sdk_root>
       ${0##*/} -h | --help

Reassemble an SDK whose .repo metadata was stripped back into a set of git
repositories.

Arguments:
  <path_to_sdk_root>   SDK root. Must already exist.

Options:
  -h, --help           Print this text and exit. Checks nothing, touches
                       nothing.

Stages:
  Step 0  Scan for dangling .git symlinks; write them to subprojects.txt.
          Skipped when that file already exists, so a hand-corrected list
          is never overwritten.
  Step 1  git init plus an initial commit in each subproject. Local only.
  Step 2  Generate default.xml (the repo manifest) from subprojects.txt.
  Step 3  Create the GitLab projects and push. Commented out in main() by
          default; uncomment when you mean it.

Configuration:
  No command line switches. GITLAB_URL, GITLAB_TOKEN, GITLAB_GROUP,
  DEFAULT_BRANCH, GIT_USER_NAME and GIT_USER_EMAIL are hardcoded in the
  configuration block of func_1_2_prepare_everything. Edit this file to
  change them.

Outputs (written to the current working directory, not the SDK root):
  subprojects.txt      Subproject paths, one per line.
  default.xml          The repo manifest.

Cautions:
  * Step 1 runs rm -rf .git in every subproject. The original symlinks are
    not recoverable. Back up first, or run Step 0 alone and inspect
    subprojects.txt before going further.
  * Step 3 pushes with -f, overwriting the matching remote branch.
  * The configuration block holds a GitLab token in cleartext. Do not
    commit this file to a public repository.
EOF
}

func_1_2_prepare_everything(){
    if [ "$#" -ne 1 ]; then
        # A usage error is diagnostic output, so it goes to stderr and leaves
        # a piped stdout clean.
        func_1_1_show_help >&2
        exit 1
    fi

    if [ ! -d "$1" ]; then
        echo "Error: Directory '$1' does not exist."
        exit 1
    fi

    # ==================== 配置区 ====================
    # misc
    BASH_SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
    BASH_SCRIPT_DIR="$(dirname "${BASH_SCRIPT_PATH}")"
    readonly RUN_DIR="$(pwd -P)"
    abs_path="$(realpath "$1")"
    echo "SDK root: ${abs_path}"
    SDK_ROOT="${abs_path}"

    # gitlab server
    GITLAB_URL="http://192.168.3.67"         # 你的 GitLab 地址
    GITLAB_TOKEN="glpat-ko70XgMzaZFqmrHrBsgmYW86MQp1OjMH.01.0w0i90gtx"      # 你的 GitLab Personal Access Token (需要 api 权限)
    GITLAB_GROUP="RK3576"                    # GitLab 上的 Group 名称

    # git ops
    DEFAULT_BRANCH="main"                       # 默认分支名
    GIT_USER_NAME="bilei"                    # Git 用户名
    GIT_USER_EMAIL="1811783168@qq.com"

    # files
    MANIFEST_FILE="${RUN_DIR}/default.xml"
    SUBPROJECTS_FILE="${RUN_DIR}/subprojects.txt"
    # ================================================
}

# ==================== 阶段 0：扫描子工程 (仅需执行一次) ====================
func_step0_scan_subprojects(){
    echo -e"\n"
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
    echo -e"\n"
    echo ">>> [Step 1] 开始本地初始化 git 仓库并提交..."

    while IFS= read -r rel_path; do
        [ -z "$rel_path" ] && continue

        # abs_path="${SDK_ROOT}/${rel_path}"
        echo "Processing local git: $rel_path"

        cd "$rel_path"
        rm -rf .git # 删除原来的旧/错软链接
        git init -b "${DEFAULT_BRANCH}"
        git config user.name "${GIT_USER_NAME}"
        git config user.email "${GIT_USER_EMAIL}"
        git add .
        git commit -m "Initial commit: Reconstruct SDK baseline"

    done < "$SUBPROJECTS_FILE"

    cd "${BASH_SCRIPT_DIR}"
    echo ">>> [Step 1] 所有子工程本地 Git 初始化完成！"
}

# ==================== 阶段 2：生成 Manifest (default.xml) ====================
func_step2_create_manifest(){
    echo -e"\n"
    echo ">>> [Step 2] 开始生成 $MANIFEST_FILE ..."

    cat <<EOF > "$MANIFEST_FILE"
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remote name="origin" fetch="${GITLAB_URL}/${GITLAB_GROUP}/" review="${GITLAB_URL}/" />
  <default revision="${DEFAULT_BRANCH}" remote="origin" sync-j="4" />

EOF

    while IFS= read -r rel_path; do
        [ -z "$rel_path" ] && continue

        repo_name=$(echo "$rel_path" | tr '/' '-')

        # 注意：这里必须是相对路径 rel_path！
        echo "  <project path=\"${rel_path}\" name=\"${repo_name}.git\" />" >> "$MANIFEST_FILE"
    done < "$SUBPROJECTS_FILE"

    echo "</manifest>" >> "$MANIFEST_FILE"
    echo ">>> [Step 2] $MANIFEST_FILE 生成完毕！"
}

# ==================== 阶段 3：GitLab 建库并 Push ====================
func_step3_push_to_remote(){
    echo -e"\n"
    echo ">>> [Step 3] 开始创建远程仓库并 Push..."

    AUTH_URL=$(echo "${GITLAB_URL}" | sed -E "s#(https?://)#\1oauth2:${GITLAB_TOKEN}@#")

    while IFS= read -r rel_path; do
        [ -z "$rel_path" ] && continue

        repo_name=$(echo "$rel_path" | tr '/' '-')

        echo "=================================================="
        echo "Pushing: $rel_path -> Remote: $repo_name"
        echo "=================================================="

        # 1. API 建库
        curl --silent --request POST "${GITLAB_URL}/api/v4/projects" \
            --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
            --data "name=${repo_name}&path=${repo_name}&namespace_id=$(curl --silent --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" "${GITLAB_URL}/api/v4/groups/${GITLAB_GROUP}" | grep -o '"id":[0-9]*' | head -1 | awk -F: '{print $2}')&visibility=private" > /dev/null || true

        # 2. Push 代码
        cd "$rel_path"
        git remote remove origin 2>/dev/null || true
        git remote add origin "${AUTH_URL}/${GITLAB_GROUP}/${repo_name}.git"
        git push -u origin "${DEFAULT_BRANCH}" -f

        # 可选：按回车单步调试 Push
        # read -p "Press Enter to continue to next push..."

    done < "$SUBPROJECTS_FILE"

    cd "${BASH_SCRIPT_DIR}"
    echo ">>> [Step 3] 全部子工程已成功 Push 到 GitLab！"
}

main() {
    # Handled before anything else, so --help works even with no arguments,
    # a nonexistent path, or a machine that has no GitLab access at all.
    # Also before the "Starting..." banner, which would otherwise be a lie.
    case "${1:-}" in
        -h|--help)
            func_1_1_show_help
            exit 0
            ;;
    esac

    echo "Starting the rebuild process..."

    func_1_2_prepare_everything "$@"

    func_step0_scan_subprojects
    func_step1_local_init_all
    func_step2_create_manifest
    #func_step3_push_to_remote
}

main "$@"