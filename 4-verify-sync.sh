#!/bin/bash
set -e

# ============================================================================
# 1_0  Libraries
# ============================================================================

# func_1_0_load_libs: source the shared libraries.
#
# gitlab.sh and gitrepo.sh are NOT sourced: this script never contacts a server
# and never runs a git command. It reads two directory trees and writes a
# report. Sourcing the git libraries would advertise capabilities it does not
# use and invite a future edit to start using them.
func_1_0_load_libs(){
    local libs
    libs="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/libs"

    . "$libs/utils.sh"   # first: everything below calls libutils_die
    . "$libs/args.sh"
    . "$libs/fstree.sh"
    . "$libs/compare.sh"
    . "$libs/report.sh"
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
Usage: ${0##*/} --baseline-dir=DIR --candidate-dir=DIR [options]
       ${0##*/} -h | --help

Compare two directory trees and report every way they differ. Written to check
that an SDK fetched with 'repo init' and 'repo sync' matches the packaged SDK
it was built from, but it knows nothing about SDKs: it compares the two
directories it is given.

Whatever you name is what gets compared. Pass two SDK roots to check the whole
thing, or two subdirectories to check that part of it -- there is no option for
narrowing the scope, because the arguments already are the scope.

READ-ONLY. Neither tree is modified.

The report goes to stdout. Progress narration goes to stderr, so the two never
mix: redirect stdout to keep the report, and the narration still reaches your
terminal while the run is going.

  ${0##*/} --baseline-dir=A --candidate-dir=B            report on screen
  ${0##*/} --baseline-dir=A --candidate-dir=B > rep.txt  report in a file

There is no --output option, because '>' already is one and is better at it:
it also does '>>', '| less', '| grep FAIL', and a pipe into another program.

Arguments:
  --baseline-dir=DIR   The tree that is presumed correct -- the vendor's original.
  --candidate-dir=DIR  The tree being checked -- the one 'repo sync' produced.

  Both are named options rather than bare positional arguments, so that a
  directory whose own name is 'baseline-dir' can never be mistaken for the
  option that selects it, and so that the two cannot be given in the wrong
  order by accident.

  The order decides how findings are worded, not which checks run. An entry
  present only in the baseline is something the rebuild lost; one present only
  in the candidate is something it invented. Those are different problems, so
  swapping the two produces a differently worded report.

Options:
  --work-dir=DIR     Where to keep the listings the report is computed from.
                     default a directory under \$TMPDIR, removed on exit
                     Name one to keep them: when the report says 4703
                     permissions differ, the file those lines came from is the
                     only way to check that for yourself. A directory you name
                     is never removed; the default one always is.
  --skip-content     Skip the byte-for-byte file comparison (section 6).
                     The other five sections read only directory metadata and
                     finish in seconds; section 6 reads every byte of both
                     trees. Use this for a fast structural check, and be aware
                     that a report produced with it cannot tell you the files
                     are identical -- only that they are all present.
  -h, --help         Print this text and exit. Checks nothing.

  Underscores and hyphens are interchangeable. Both --key=value and --key value
  are accepted.

What is compared, in order. Every section ends in PASS, FAIL or SKIP:
  1. Top level          Immediate children of each root. A whole missing
                        subtree shows up here as one line instead of as tens of
                        thousands of missing-file lines in section 2.
  2. Structure          Every entry in both trees, with its type. Type is part
                        of the comparison: a path that is a file in one tree
                        and a symlink in the other is a difference.
  3. Empty directories  Reported separately because the cause is specific and
                        unavoidable -- git cannot represent an empty directory,
                        so one in a packaged tree is always absent from a clone
                        of it, and no amount of re-syncing will fix that.
  4. Symlink targets    Compared as text, not resolved. Two links that resolve
                        to the same file today but are written differently are
                        not the same link.
  5. Permissions        Grouped by transition, then split. Differences confined
                        to group and other bits are flagged as consistent with
                        a differing umask -- git records only the owner execute
                        bit, so it cannot carry the rest, and a shell with a
                        different umask supplies them. Those are summarised as
                        counts. Anything else, including every difference in
                        the owner execute bit, is listed path by path, because
                        that bit IS in the commit.
  6. Content            Every file, byte for byte, symlinks not followed.

What is excluded, everywhere:
  .git and .repo directories, and everything under them. They hold version
  control metadata, not tree content: a clone and its origin differ wildly
  inside .git while being identical in every file that matters, and comparing
  them buries every real finding. Nothing else is excluded -- a build artefact
  present in one tree only IS a difference and is reported as one.

Exit status:
  0  PASS        every section ran and found no difference
  1  FAIL        a section found a difference, or the run could not proceed
  1  INCOMPLETE  no difference found, but a section was skipped, so the trees
                 were not verified to match. Non-zero on purpose: this result
                 must not gate anything that a PASS would be allowed to gate.
EOF
}

# ============================================================================
# 1_2  Option vocabulary
# ============================================================================

# func_1_2_check_options: define the accepted options and reject anything else.
#
# $@ -- the caller's raw arguments
#
# Without the whitelist a typo like --skip_conten is ignored, the byte-for-byte
# comparison runs when the operator meant to skip it, and the only symptom is
# that the run takes twenty minutes instead of ten seconds. The reverse typo is
# worse: --skip-contentt would be ignored too, but on a report the operator
# then reads as a full verification when it was not one.
func_1_2_check_options(){
    OPTION_NAMES="baseline-dir candidate-dir work-dir skip-content help"

    libargs_check_known "$OPTION_NAMES" "$@"
}

# ============================================================================
# 1_3  Trees
# ============================================================================

# func_1_3_init_trees: resolve and validate the two trees to compare.
#
# $@ -- the caller's raw arguments
#
# Both paths are made absolute and physical before anything else uses them.
# Section 6 embeds them in diff's output and strips them back off again by
# string match; a relative path would defeat that, and two spellings of one
# directory would make the strip silently miss.
func_1_3_init_trees(){
    local baseline candidate

    # libargs_has before libargs_get, so "never mentioned" and "mentioned with
    # an empty value" get different messages. They are different mistakes: the
    # first is a forgotten option, the second an unset shell variable that
    # expanded to nothing, and an operator hunting the second one needs to be
    # told the option was seen.
    libargs_has baseline-dir "$@" || \
        libutils_die "no --baseline-dir given (try --help)"
    libargs_has candidate-dir "$@" || \
        libutils_die "no --candidate-dir given (try --help)"

    baseline=$(libargs_get baseline-dir "" "$@")
    candidate=$(libargs_get candidate-dir "" "$@")

    [ -n "$baseline" ] || libutils_die "--baseline-dir is empty"
    [ -n "$candidate" ] || libutils_die "--candidate-dir is empty"

    libfstree_require_dir "$baseline" baseline
    libfstree_require_dir "$candidate" candidate

    BASELINE=$(libfstree_abs "$baseline")
    CANDIDATE=$(libfstree_abs "$candidate")

    # Comparing a tree with itself always passes and therefore proves nothing.
    # It is a plausible slip -- two paths that differ only by a symlinked
    # parent -- and a PASS obtained this way is the most misleading output this
    # script could produce.
    [ "$BASELINE" != "$CANDIDATE" ] || \
        libutils_die "both arguments resolve to the same directory: $BASELINE"

    # One tree inside the other means section 6 recurses into the candidate
    # while walking the baseline, comparing files against themselves and
    # producing a result no one can interpret. Rejected rather than warned
    # about, because there is no correct way to proceed.
    case "$CANDIDATE/" in
        "$BASELINE"/*) libutils_die "candidate is inside baseline; nothing sensible to compare" ;;
    esac
    case "$BASELINE/" in
        "$CANDIDATE"/*) libutils_die "baseline is inside candidate; nothing sensible to compare" ;;
    esac
}

# ============================================================================
# 1_4  Working files
# ============================================================================

# func_1_4_init_paths: choose the working directory and arrange its removal.
#
# $@ -- the caller's raw arguments
#
# Created now, before the slow phases, so a run that cannot write its working
# files fails in the first second rather than after twenty minutes of
# comparison.
#
# There is no report path to compute: the report goes to stdout.
#
# Two kinds of working directory, and the difference is who cleans up. A
# directory the operator named is theirs -- they asked to keep the listings, so
# removing them would destroy the evidence they asked for. The default one is
# ours, under TMPDIR, and is removed on exit: a tool run repeatedly on 33 GB
# trees that left a listing directory behind every time would silently fill the
# disk, and nobody asked for those files.
func_1_4_init_paths(){
    local work

    work=$(libargs_get work-dir "" "$@")

    if [ -n "$work" ]; then
        # Absolute, because the report prints this path for a reader who may be
        # standing in a different directory than the run was.
        case "$work" in
            /*) WORK_DIR="$work" ;;
            *)  WORK_DIR="$(pwd -P)/$work" ;;
        esac
        WORK_DIR_IS_OURS=no

        mkdir -p "$WORK_DIR" || libutils_die "cannot create work directory: $WORK_DIR"
    else
        WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/verify-sync.XXXXXX") || \
            libutils_die "cannot create a temporary work directory under ${TMPDIR:-/tmp}"
        WORK_DIR_IS_OURS=yes
    fi

    [ -w "$WORK_DIR" ] || libutils_die "work directory is not writable: $WORK_DIR"

    BODY="${WORK_DIR}/report.body"

    # Registered after WORK_DIR is known and only for a directory we created.
    # EXIT alone is not enough: the trap fires on 'set -e' and on a normal
    # return, but a Ctrl-C during section 6 is a signal, and without INT and
    # TERM the interrupted run -- the likeliest one, since it is the slow one --
    # would be the one that leaks its listings.
    if [ "$WORK_DIR_IS_OURS" = yes ]; then
        trap func_1_4_cleanup EXIT INT TERM
    fi

    # Stale listings from an earlier run against different trees would be read
    # by this run's comparisons and produce findings belonging to neither tree.
    # Cannot happen in a fresh mktemp directory; can happen in a named one that
    # is being reused, which is the point of allowing it to be named.
    rm -f "${WORK_DIR}"/*.lst "${WORK_DIR}"/*.diff "${WORK_DIR}"/*.tally 2>/dev/null || true
}

# func_1_4_cleanup: remove the working directory we created.
#
# Guards on WORK_DIR_IS_OURS as well as being installed only in that case,
# because a trap outlives the reasoning that installed it: a later edit that
# moves the trap earlier would otherwise delete a directory the operator named.
#
# Deleting a tree from a trap is worth being paranoid about. The guards are
# what stand between a bug and 'rm -rf /': the variable must be non-empty, must
# be ours, and must still look like the mktemp path we made.
func_1_4_cleanup(){
    [ "${WORK_DIR_IS_OURS:-no}" = yes ] || return 0
    [ -n "${WORK_DIR:-}" ] || return 0

    case "$WORK_DIR" in
        */verify-sync.??????) rm -rf "$WORK_DIR" ;;
    esac
}

# ============================================================================
# 1_5  Run configuration
# ============================================================================

func_1_5_init_run_config(){
    if libargs_is_true skip-content "$@"; then
        SKIP_CONTENT=yes
    else
        SKIP_CONTENT=no
    fi

    # Recorded in the report header. A report that does not say when it was
    # produced cannot be told apart from one produced before the last re-sync,
    # and the wrong one will be trusted.
    RUN_STAMP=$(date '+%Y-%m-%d %H:%M:%S %Z')
}

# ============================================================================
# 1_6  Dependency check
# ============================================================================

# func_1_6_check_deps: die unless the tools every section needs are present.
#
# Checked up front. Discovering that join is missing after section 6 has read
# 18 GB wastes the entire run, and every one of these is used by some section.
func_1_6_check_deps(){
    libutils_require_cmd find sort comm join awk sed cut uniq wc diff grep head tr date
}

# ============================================================================
# 1_7  Configuration report
# ============================================================================

# func_1_7_report_config: print what this run will do, before it does it.
#
# Printed to the terminal, not the report. Its purpose is to let the operator
# stop a run pointed at the wrong tree within the first second, which is only
# possible if it appears before the walking starts.
func_1_7_report_config(){
    libutils_say "baseline:  ${BASELINE}"
    libutils_say "candidate: ${CANDIDATE}"
    if [ "$WORK_DIR_IS_OURS" = yes ]; then
        libutils_say "work dir:  ${WORK_DIR} (temporary, removed on exit)"
    else
        libutils_say "work dir:  ${WORK_DIR} (kept)"
    fi
    if [ "$SKIP_CONTENT" = yes ]; then
        libutils_say "content:   SKIPPED (--skip-content)"
    else
        libutils_say "content:   full byte-for-byte comparison"
    fi
    echo >&2
}

# ============================================================================
# 2_0  Listings
# ============================================================================

# func_2_0_build_listings: walk both trees once and write every listing.
#
# Both trees are walked completely here, and every later section reads the
# files this produces rather than walking again. On an 18 GB tree the walk is
# the expensive part of the metadata phases, and five sections each doing their
# own would multiply the cost by five for identical results.
func_2_0_build_listings(){
    local tree side

    for side in baseline candidate; do
        if [ "$side" = baseline ]; then tree="$BASELINE"; else tree="$CANDIDATE"; fi

        libutils_say "listing ${side} ..."
        libfstree_warn_odd_names "$tree"
        libfstree_list_top        "$tree" "${WORK_DIR}/${side}-top.lst"
        libfstree_list_entries    "$tree" "${WORK_DIR}/${side}-entries.lst"
        libfstree_list_modes      "$tree" "${WORK_DIR}/${side}-modes.lst"
        libfstree_list_links      "$tree" "${WORK_DIR}/${side}-links.lst"
        libfstree_list_empty_dirs "$tree" "${WORK_DIR}/${side}-empty.lst"
    done
    echo >&2
}

# ============================================================================
# 3_0  Sections
# ============================================================================

# func_3_0_one_sided_section: the shape shared by sections 1 to 4.
#
# $1 -- section number
# $2 -- section title
# $3 -- listing basename ("top", "entries", "empty", "links")
# $4 -- what one line of the listing represents, for the wording
# $5 -- how many lines to show before pointing at the full file
# $6 -- name of the variable to store this section's finding count in
#
# One function rather than four near-copies, because four copies of this
# reporting logic is four places for the wording and the counting to drift
# apart -- and a report whose stated count disagrees with its own list is not
# usable.
# func_3_0_where: say where a truncated list can be read in full.
#
# $1 -- the working file holding the complete list
#
# One place, because the answer depends on something no single call site should
# have to remember: the default working directory is deleted when the run ends,
# so printing its path invites a reader to go looking for a file that is no
# longer there. When the directory is temporary, the report says how to keep it
# instead of naming a path that will be gone by the time it is read.
func_3_0_where(){
    if [ "$WORK_DIR_IS_OURS" = yes ]; then
        echo "re-run with --work-dir=DIR to keep the full list"
    else
        echo "full list: $1"
    fi
}

func_3_0_one_sided_section(){
    local number="$1" title="$2" base="$3" noun="$4" limit="$5" outvar="$6"
    local lost_file gained_file lost gained

    lost_file="${WORK_DIR}/${base}-missing.diff"
    gained_file="${WORK_DIR}/${base}-extra.diff"

    lost=$(libcompare_only_in_first \
        "${WORK_DIR}/baseline-${base}.lst" "${WORK_DIR}/candidate-${base}.lst" "$lost_file")
    gained=$(libcompare_only_in_second \
        "${WORK_DIR}/baseline-${base}.lst" "${WORK_DIR}/candidate-${base}.lst" "$gained_file")

    libreport_section "$BODY" "$number" "$title"

    libreport_line "$BODY" "baseline  $(wc -l < "${WORK_DIR}/baseline-${base}.lst" | tr -d ' ') ${noun}"
    libreport_line "$BODY" "candidate $(wc -l < "${WORK_DIR}/candidate-${base}.lst" | tr -d ' ') ${noun}"
    libreport_line "$BODY" ""

    if [ "$lost" -gt 0 ]; then
        libreport_line "$BODY" "IN BASELINE ONLY -- the rebuild did not reproduce these (${lost}):"
        libreport_list "$BODY" "$lost_file" "$limit" "    " "$(func_3_0_where "$lost_file")"
        libreport_line "$BODY" ""
    fi

    if [ "$gained" -gt 0 ]; then
        libreport_line "$BODY" "IN CANDIDATE ONLY -- these are not in the baseline (${gained}):"
        libreport_list "$BODY" "$gained_file" "$limit" "    " "$(func_3_0_where "$gained_file")"
        libreport_line "$BODY" ""
    fi

    if [ "$lost" -eq 0 ] && [ "$gained" -eq 0 ]; then
        libreport_verdict "$BODY" PASS "both trees hold the same ${noun}"
    else
        libreport_verdict "$BODY" FAIL "${lost} only in baseline, ${gained} only in candidate"
    fi

    # printf -v rather than eval: the value is arithmetic here and so always
    # safe, but eval on a computed string is a habit that stops being safe the
    # first time someone widens what this function reports.
    printf -v "$outvar" '%s' "$((lost + gained))"
}

# func_3_1_section_top: section 1, the immediate children of each root.
func_3_1_section_top(){
    libutils_say "section 1: top level"
    func_3_0_one_sided_section 1 "Top level" top "top-level entries" 0 N_TOP
}

# func_3_2_section_structure: section 2, every entry in both trees.
#
# Capped at 200 shown lines. A missing subtree produces thousands of lines that
# all follow from one cause, and a reader who has to scroll past them stops
# reading before section 5.
func_3_2_section_structure(){
    libutils_say "section 2: structure"
    func_3_0_one_sided_section 2 "Structure (every entry, with type)" entries "entries" 200 N_ENTRIES
}

# func_3_3_section_empty: section 3, directories holding nothing.
#
# Uncapped: this list is short by nature, and it is the one list an operator
# will want to act on in full, since each line is a directory that has to be
# recreated by hand after every sync.
func_3_3_section_empty(){
    libutils_say "section 3: empty directories"
    func_3_0_one_sided_section 3 "Empty directories" empty "empty directories" 0 N_EMPTY

    libreport_line "$BODY" ""
    libreport_line "$BODY" "Note: git has no way to store an empty directory. One present in the"
    libreport_line "$BODY" "baseline and absent from the candidate is therefore expected, and will"
    libreport_line "$BODY" "recur on every fresh sync -- it is not a transient fault. Closing the gap"
    libreport_line "$BODY" "needs either a placeholder file committed into each such directory, which"
    libreport_line "$BODY" "makes the candidate differ by that file instead, or a post-sync step that"
    libreport_line "$BODY" "recreates them from a recorded list."
}

# func_3_4_section_links: section 4, symlink targets as written.
func_3_4_section_links(){
    libutils_say "section 4: symlink targets"
    func_3_0_one_sided_section 4 "Symlink targets" links "symlinks" 100 N_LINKS
}

# func_3_5_section_modes: section 5, permission bits.
#
# The only section that does not use func_3_0_one_sided_section, because it is
# not a set comparison: every path here exists in both trees and differs in a
# value. Its whole difficulty is separating one systematic cause from a
# specific fault, which the one-sided shape has no way to express.
func_3_5_section_modes(){
    local diffs tally unexplained n_diffs n_unexplained

    libutils_say "section 5: permissions"

    diffs="${WORK_DIR}/modes.diff"
    tally="${WORK_DIR}/modes.tally"
    unexplained="${WORK_DIR}/modes-unexplained.diff"

    n_diffs=$(libcompare_modes \
        "${WORK_DIR}/baseline-modes.lst" "${WORK_DIR}/candidate-modes.lst" "$diffs" "$tally")
    n_unexplained=$(libcompare_modes_unexplained "$diffs" "$tally" "$unexplained")

    libreport_section "$BODY" 5 "Permissions"

    libreport_line "$BODY" "Mode histogram, baseline:"
    libfstree_mode_histogram "${WORK_DIR}/baseline-modes.lst" | sed 's/^/    /' >> "$BODY"
    libreport_line "$BODY" ""
    libreport_line "$BODY" "Mode histogram, candidate:"
    libfstree_mode_histogram "${WORK_DIR}/candidate-modes.lst" | sed 's/^/    /' >> "$BODY"
    libreport_line "$BODY" ""

    if [ "$n_diffs" -eq 0 ]; then
        libreport_verdict "$BODY" PASS "every entry present in both trees has identical permissions"
        N_MODES=0
        return 0
    fi

    libreport_line "$BODY" "${n_diffs} entries differ. By transition (count, type, baseline, candidate, class):"
    libreport_line "$BODY" ""
    sed 's/^/    /' "$tally" >> "$BODY"
    libreport_line "$BODY" ""
    libreport_line "$BODY" "Class 'umask' means the owner's bits are identical and only the group or"
    libreport_line "$BODY" "other bits differ. Git stores one permission bit per file -- the owner"
    libreport_line "$BODY" "execute bit -- so it cannot carry the rest; they come from the umask of"
    libreport_line "$BODY" "the shell that created the file. A whole tree shifted this way points at"
    libreport_line "$BODY" "the environment, not at the commit: umask 022 yields 755 and 644, umask"
    libreport_line "$BODY" "002 yields 775 and 664. This is consistency, not proof -- it is what a"
    libreport_line "$BODY" "umask difference looks like, and nothing here rules out another cause."
    libreport_line "$BODY" ""
    libreport_line "$BODY" "Class 'owner-exec' is never dismissed: that bit IS in the commit, so a"
    libreport_line "$BODY" "difference means the two trees disagree about whether a file is runnable."
    libreport_line "$BODY" ""

    if [ "$n_unexplained" -gt 0 ]; then
        libreport_line "$BODY" "NOT EXPLAINED BY A UMASK DIFFERENCE (${n_unexplained}) -- read these:"
        libreport_line "$BODY" "(type, baseline mode, candidate mode, path)"
        libreport_list "$BODY" "$unexplained" 200 "    " "$(func_3_0_where "$unexplained")"
        libreport_line "$BODY" ""
        libreport_verdict "$BODY" FAIL "${n_unexplained} of ${n_diffs} differences are not umask-consistent"
    else
        libreport_line "$BODY" "Every difference is confined to group and other bits."
        libreport_line "$BODY" "$(func_3_0_where "$diffs")"
        libreport_line "$BODY" ""
        libreport_verdict "$BODY" FAIL "${n_diffs} entries differ, all umask-consistent (see the note above)"
    fi

    N_MODES="$n_diffs"
    N_MODES_UNEXPLAINED="$n_unexplained"
}

# func_3_6_section_content: section 6, every file byte for byte.
#
# The slow one, and last on purpose: the metadata sections finish in seconds,
# so an operator watching the terminal has already seen most of the findings by
# the time this starts.
func_3_6_section_content(){
    local out raw trouble n_diff n_trouble

    libreport_section "$BODY" 6 "Content (byte for byte)"

    if [ "$SKIP_CONTENT" = yes ]; then
        libutils_say "section 6: content -- SKIPPED"
        libreport_line "$BODY" "Skipped: --skip-content was given."
        libreport_line "$BODY" ""
        libreport_line "$BODY" "This report therefore does NOT establish that the files are identical."
        libreport_line "$BODY" "Sections 1 to 5 read directory metadata only: they can show that every"
        libreport_line "$BODY" "file is present, named alike and permitted alike, and say nothing"
        libreport_line "$BODY" "whatever about what is inside them."
        libreport_verdict "$BODY" SKIP "not checked -- content comparison was skipped"
        N_CONTENT=-1
        return 0
    fi

    libutils_say "section 6: content -- reading every byte of both trees, this is the slow part ..."

    out="${WORK_DIR}/content.diff"
    raw="${WORK_DIR}/content-raw.diff"
    trouble="${WORK_DIR}/content-trouble.diff"

    n_diff=$(libcompare_content "$BASELINE" "$CANDIDATE" "$out" "$raw")
    n_trouble=$(libcompare_content_trouble "$raw" "$trouble")

    libreport_line "$BODY" "Compared with: diff -qr --no-dereference, excluding .git and .repo."
    libreport_line "$BODY" "Symlinks are compared as links, not followed."
    libreport_line "$BODY" ""

    if [ "$n_diff" -gt 0 ]; then
        libreport_line "$BODY" "FILES WHOSE CONTENT DIFFERS (${n_diff}):"
        libreport_list "$BODY" "$out" 200 "    " "$(func_3_0_where "$out")"
        libreport_line "$BODY" ""
    fi

    # Reported whatever the verdict. A file diff could not read is a file this
    # script did not verify, and a report that stays silent about it would be
    # claiming a check it never performed.
    if [ "$n_trouble" -gt 0 ]; then
        libreport_line "$BODY" "PATHS diff COULD NOT COMPARE (${n_trouble}) -- these were NOT verified:"
        libreport_list "$BODY" "$trouble" 100 "    " "$(func_3_0_where "$trouble")"
        libreport_line "$BODY" ""
    fi

    if [ "$n_diff" -eq 0 ] && [ "$n_trouble" -eq 0 ]; then
        libreport_verdict "$BODY" PASS "every file present in both trees is byte-for-byte identical"
    else
        libreport_verdict "$BODY" FAIL "${n_diff} file(s) differ, ${n_trouble} path(s) could not be compared"
    fi

    N_CONTENT="$n_diff"
    N_CONTENT_TROUBLE="$n_trouble"
}

# ============================================================================
# 4_0  Assembly
# ============================================================================

# func_4_0_decide_overall: set OVERALL from the section counts.
#
# Separate from func_4_0_summary because that function's output is captured in a
# command substitution, and a variable assigned inside one is assigned in a
# subshell and lost. Deciding the verdict here, in the caller's own shell, is
# what makes OVERALL available to the exit status -- computing it inside the
# summary left it empty and the script exited 0 on a failing comparison.
#
# Three states, not two. A count of -1 means the section did not run, and
# folding that into either PASS or FAIL loses the distinction that matters
# most: PASS would claim the files were checked and found identical when they
# were never read, and FAIL would report a difference nothing found. INCOMPLETE
# says what happened. It exits non-zero like FAIL, because a run that skipped a
# section has not verified the trees match and must not gate anything.
func_4_0_decide_overall(){
    local failed=no skipped=no

    func_4_0_tally_section "$N_TOP"
    func_4_0_tally_section "$N_ENTRIES"
    func_4_0_tally_section "$N_EMPTY"
    func_4_0_tally_section "$N_LINKS"
    func_4_0_tally_section "$N_MODES"
    func_4_0_tally_section "$N_CONTENT"

    if [ "$failed" = yes ]; then
        OVERALL=FAIL
    elif [ "$skipped" = yes ]; then
        OVERALL=INCOMPLETE
    else
        OVERALL=PASS
    fi
}

# func_4_0_tally_section: fold one section's count into failed/skipped.
#
# $1 -- the count, or -1 for a section that did not run
#
# Assigns to its caller's locals rather than taking them as arguments, which is
# why it is not a pure function: the alternative is repeating the same case
# statement six times, and a sixth copy that drifts from the other five is a
# verdict that silently disagrees with the summary beside it.
func_4_0_tally_section(){
    case "$1" in
        -1) skipped=yes ;;
        0)  ;;
        *)  failed=yes ;;
    esac
}

# func_4_0_summary: build the summary block that goes at the top.
#
# Written after every section has run, because it states their counts. A
# summary at the top is what makes the report answerable at a glance; a summary
# computable before the work is done would not be one.
func_4_0_summary(){
    cat <<EOF
SUMMARY
-------
  1. Top level              $(func_4_1_verdict_word "$N_TOP") ($N_TOP differing entries)
  2. Structure              $(func_4_1_verdict_word "$N_ENTRIES") ($N_ENTRIES differing entries)
  3. Empty directories      $(func_4_1_verdict_word "$N_EMPTY") ($N_EMPTY differing directories)
  4. Symlink targets        $(func_4_1_verdict_word "$N_LINKS") ($N_LINKS differing symlinks)
  5. Permissions            $(func_4_1_verdict_word "$N_MODES") ($N_MODES differing entries, ${N_MODES_UNEXPLAINED:-0} not umask-consistent)
  6. Content                $(func_4_1_verdict_word "$N_CONTENT") $(func_4_2_content_note)

OVERALL: ${OVERALL}
EOF
}

# func_4_1_verdict_word: print PASS, FAIL or SKIP for a section's count.
#
# $1 -- the count, or -1 for a section that did not run
#
# A skipped section reads SKIP and not PASS. A zero count from a check that
# never ran would otherwise be indistinguishable from a clean result, which is
# the one confusion this tool cannot afford.
func_4_1_verdict_word(){
    case "$1" in
        -1) echo "SKIP" ;;
        0)  echo "PASS" ;;
        *)  echo "FAIL" ;;
    esac
}

func_4_2_content_note(){
    case "$N_CONTENT" in
        -1) echo "(not checked -- --skip-content)" ;;
        *)  echo "($N_CONTENT differing files, ${N_CONTENT_TROUBLE:-0} uncomparable)" ;;
    esac
}

func_4_3_header(){
    cat <<EOF
============================================================================
Tree comparison report
============================================================================
generated  ${RUN_STAMP}
baseline   ${BASELINE}
candidate  ${CANDIDATE}
excluded   .git and .repo directories, everywhere
listings   $(func_4_3_listings_note)

An entry "in baseline only" is one the rebuild failed to reproduce. One "in
candidate only" is one it introduced. Neither tree was modified by this run.
EOF
}

# func_4_3_listings_note: what the header says about the working files.
#
# Naming a temporary directory here would be worse than saying nothing: by the
# time anyone reads a saved report, that path is gone, and a reader who checks
# it concludes the report is stale rather than that the files were never kept.
func_4_3_listings_note(){
    if [ "$WORK_DIR_IS_OURS" = yes ]; then
        echo "not kept (re-run with --work-dir=DIR to keep them)"
    else
        echo "${WORK_DIR}"
    fi
}

# func_4_4_report_result: print the verdict and how to read it.
#
# On stderr, all of it. This is narration about the run, not part of the report:
# with the report on stdout, a line printed here would land in the middle of
# whatever file the operator redirected to -- after the body, under no section,
# where a later reader would take it for a finding.
func_4_4_report_result(){
    echo >&2
    libutils_say "overall: ${OVERALL}"
    echo >&2
    if [ "$OVERALL" = INCOMPLETE ]; then
        libutils_say "A section was skipped, so this run did not verify the two trees match."
        libutils_say "It found no difference in what it did compare. Re-run without"
        libutils_say "--skip-content for an answer that can be relied on."
    fi
    if [ "$OVERALL" = FAIL ]; then
        libutils_say "Read the SUMMARY at the top of the report, then the sections it marks FAIL."
        if [ "$WORK_DIR_IS_OURS" = no ]; then
            libutils_say "Every count in the summary is backed by a file in ${WORK_DIR},"
            libutils_say "named in the section that reports it."
        else
            libutils_say "To see the full list behind every count instead of the first 200"
            libutils_say "lines, re-run with --work-dir=DIR."
        fi
    fi
}

# ============================================================================
# main
# ============================================================================

# main: order matters. Both trees are validated before either is walked, and
# every listing is built before any section reads one.
main(){
    func_1_0_load_libs

    # Before anything else, so --help works with no arguments and no readable
    # directories at all.
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
    func_1_3_init_trees "$@"
    func_1_4_init_paths "$@"
    func_1_5_init_run_config "$@"
    func_1_6_check_deps
    func_1_7_report_config

    libreport_begin "$BODY"
    func_2_0_build_listings

    func_3_1_section_top
    func_3_2_section_structure
    func_3_3_section_empty
    func_3_4_section_links
    func_3_5_section_modes
    func_3_6_section_content

    func_4_0_decide_overall
    libreport_emit "$BODY" "$(func_4_3_header)" "$(func_4_0_summary)"
    func_4_4_report_result

    [ "$OVERALL" = PASS ] || exit 1
}

main "$@"
