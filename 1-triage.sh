#!/bin/bash
set -e

# ============================================================================
# 1_0  Libraries
# ============================================================================

# func_1_0_load_libs: source the shared libraries.
#
# Only utils and args: this script reads a directory tree and writes two text
# files. It never contacts a server and never modifies the tree, so the gitlab,
# gitrepo and manifest libraries would advertise capabilities it does not use.
func_1_0_load_libs(){
    local libs
    libs="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/libs"

    . "$libs/utils.sh"   # first: everything below calls libutils_die
    . "$libs/args.sh"
}

# ============================================================================
# 1_1  Help
# ============================================================================

# func_1_1_show_help: print the usage text.
#
# Unquoted <<EOF so ${0##*/} expands to the real script name.
func_1_1_show_help(){
    cat <<EOF
Usage: ${0##*/} <path_to_sdk_root>
       ${0##*/} -h | --help

Judge, for every project in an unpacked vendor SDK tree, whether its git
history survives, and summarise the tree's fate: snapshot rebuild, wholesale
migration, or mixed. This is README chapter 2, automated.

READ-ONLY. The SDK tree is never modified. Run it against the REBUILD tree,
not the read-only baseline: the paths it writes are consumed by 2-rebuild.sh,
which works in the rebuild tree, so the paths must point there.

Arguments:
  <path_to_sdk_root>    SDK root. Must already exist.

How each project is judged (README chapter 2, second-layer diagram):
  1. Look at what .git is: a symlink, a real directory, or missing.
  2. Follow it: is there history data behind it?
  3. Prove it: 'git log -1' must actually print a commit. rev-parse can
     succeed on a hollow shell of refs with no objects; log cannot.

  The name of the central directory the links point at is never matched --
  the links themselves decide, so a store named anything (.repo, ohmygod)
  is recognised all the same.

Outputs (written to the current working directory, not the SDK root):
  triage.txt        every project found:
                    <absolute path> TAB <history|no-history> TAB <reason>
  subprojects.txt   the no-history projects, one absolute path per line.
                    This is the file 2-rebuild.sh reads. An empty file means
                    nothing needs a snapshot rebuild -- do not run 2-rebuild.sh.

Exit status:
  0  the run completed. The verdict lives in the summary and the files; a
     tree that should be migrated instead of rebuilt is not an error.
  1  the run itself could not proceed (bad arguments, missing tools).
EOF
}

# ============================================================================
# 1_2  Option vocabulary
# ============================================================================

# func_1_2_check_options: no options besides --help; reject anything else.
#
# A typo like --sdk_root would otherwise be silently ignored while the
# positional argument is misread.
func_1_2_check_options(){
    OPTION_NAMES="help"
    FLAG_NAMES="help"

    libargs_check_known "$OPTION_NAMES" "$@"
}

# ============================================================================
# 1_3  Paths and output files
# ============================================================================

# func_1_3_init_paths: settle where this run writes.
#
# RUN_DIR is the invocation directory, matching 2-rebuild.sh: the operator
# stands in salvage-work and every script's outputs land side by side.
func_1_3_init_paths(){
    RUN_DIR="$(pwd -P)"

    TRIAGE_FILE="${RUN_DIR}/triage.txt"
    SUBPROJECTS_FILE="${RUN_DIR}/subprojects.txt"
}

# ============================================================================
# 1_4  SDK root
# ============================================================================

# func_1_4_init_sdk_root: resolve the one positional argument.
#
# $@ -- the caller's raw arguments
#
# No default, same reasoning as 2-rebuild.sh: guessing '.' would let a run
# started from the wrong directory report on an unrelated tree.
func_1_4_init_sdk_root(){
    local sdk_arg
    sdk_arg=$(libargs_positional 0 "" "$FLAG_NAMES" "$@")

    if [ -z "$sdk_arg" ]; then
        func_1_1_show_help >&2
        exit 1
    fi

    if [ ! -d "$sdk_arg" ]; then
        libutils_die "SDK root does not exist: $sdk_arg"
    fi

    SDK_ROOT="$(realpath "$sdk_arg")"
}

# ============================================================================
# 1_5  Dependency check
# ============================================================================

func_1_5_check_deps(){
    libutils_require_cmd git find realpath sort awk dirname readlink
}

# ============================================================================
# Per-project classification
# ============================================================================

# func_classify_one: print one triage line for one project.
#
# $1 -- absolute path of the project directory
# $2 -- absolute path of its .git entry
#
# Output: "<proj>\t<history|no-history>\t<reason>"
#
# git log is the only verdict; the structural tests only words the failure.
# A dangling symlink and a hollow directory full of intact-looking refs are
# both 'no-history', but the operator deserves to know which one he is
# looking at when the triage file surprises him.
func_classify_one(){
    local proj="$1" git_entry="$2"
    local target

    if git -C "$proj" log -1 >/dev/null 2>&1; then
        if [ -L "$git_entry" ]; then
            printf '%s\thistory\t%s\n' "$proj" "活链接，历史可读"
        else
            printf '%s\thistory\t%s\n' "$proj" "完整目录，历史可读"
        fi
        return 0
    fi

    if [ -L "$git_entry" ]; then
        target=$(readlink -f "$git_entry" 2>/dev/null || true)
        if [ -n "$target" ] && [ -d "$target" ]; then
            printf '%s\tno-history\t%s\n' "$proj" "活链接但历史不可读（空壳）"
        else
            printf '%s\tno-history\t%s\n' "$proj" "断链符号链接"
        fi
    else
        printf '%s\tno-history\t%s\n' "$proj" "骨架/目录，历史不可读"
    fi
}

# ============================================================================
# The one pass
# ============================================================================

# func_triage_all: classify every project, write both files, print the verdict.
#
# The summary tells the operator which of the three fates applies and what to
# do next, so a correct run needs no interpretation of the raw files.
func_triage_all(){
    local git_entry proj line verdict
    local total=0 n_history=0 n_none=0

    libutils_say "扫描 ${SDK_ROOT} 下的 .git ..."
    : > "$TRIAGE_FILE"

    while IFS= read -r git_entry; do
        proj=$(realpath "$(dirname "$git_entry")")
        line=$(func_classify_one "$proj" "$git_entry")
        echo "$line" >> "$TRIAGE_FILE"

        verdict=$(echo "$line" | cut -f2)
        total=$((total + 1))
        if [ "$verdict" = history ]; then
            n_history=$((n_history + 1))
        else
            n_none=$((n_none + 1))
        fi

        # A heartbeat on big trees: 1000+ projects with no output looks hung.
        if [ $((total % 100)) -eq 0 ]; then
            libutils_say "已判定 ${total} 个项目 ..."
        fi
    done < <(find "$SDK_ROOT" -name .git \( -type l -o -type d \) | sort)

    awk -F'\t' '$2=="no-history"{print $1}' "$TRIAGE_FILE" > "$SUBPROJECTS_FILE"

    echo "=================================================="
    echo "判定完成：共 ${total} 个项目，有历史 ${n_history} 个，无历史 ${n_none} 个。"
    echo "明细：${TRIAGE_FILE}"
    echo "清单：${SUBPROJECTS_FILE}（$(wc -l < "$SUBPROJECTS_FILE" | tr -d ' ') 行，供 2-rebuild.sh 使用）"

    if [ "$total" -eq 0 ]; then
        echo "形态：全树没有任何 .git（rk3576 即这种）。无历史可救，全部按快照重建。"
        echo "下一步：项目边界需要手工划定后写入 ${SUBPROJECTS_FILE}，"
        echo "        生成命令见 README 第一章第 2 步的「⚠️ 卡住了」。"
    elif [ "$n_history" -eq 0 ]; then
        echo "形态：全部无历史 → 快照重建。"
        echo "下一步：2-rebuild.sh ${SDK_ROOT} --push ...（README 第一章第 3 步）"
    elif [ "$n_history" -eq "$total" ]; then
        echo "形态：全部有历史 → 整体搬迁。不要跑 2-rebuild.sh。"
        echo "下一步：按 README 附录 D，原样 push 历史 + 改写 manifest 地址。"
    else
        echo "形态：混合。有历史的 ${n_history} 个已在 ${SUBPROJECTS_FILE} 中剔除。"
        echo "下一步：先按 README 附录 D 搬迁这些项目（见 triage.txt 里的 history 行），"
        echo "        再跑 2-rebuild.sh 处理其余项目。"
    fi
}

# ============================================================================
# main
# ============================================================================

main() {
    func_1_0_load_libs

    # Before anything else, so --help works with no arguments and no tree.
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

    # Built-in stopwatch (libs/utils.sh): the operator keeps forgetting `time`.
    # No other EXIT trap exists in this script, so a plain install is safe.
    libutils_clock_start
    trap libutils_clock_report EXIT

    func_1_2_check_options "$@"
    func_1_3_init_paths
    func_1_4_init_sdk_root "$@"
    func_1_5_check_deps

    func_triage_all
}

main "$@"
