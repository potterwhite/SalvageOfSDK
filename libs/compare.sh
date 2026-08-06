# shellcheck shell=bash
#
# compare.sh -- Compare two listings and classify the differences.
#
# No domain knowledge: nothing here knows what an SDK is or why two trees are
# being compared. It reads the listings fstree.sh produced and writes smaller
# files describing how they differ. Presenting those findings belongs in
# report.sh.
#
# Every function is named libcompare_*, following the libs/ convention that a
# function's prefix names the file it lives in.
#
# WHY CLASSIFICATION IS THIS FILE'S REAL JOB, not just subtraction: on the
# trees this was built for, a raw permission diff runs to several thousand
# lines that all say the same thing -- one shell had a different umask -- while
# a single genuinely wrong permission sits somewhere in the middle, unread. A
# comparison that cannot separate "one systematic cause" from "one specific
# fault" is not usable, however correct its arithmetic. So mode differences are
# grouped by transition and each transition is labelled with what could have
# caused it; only the transitions no systematic cause explains are listed
# path by path.
#
# All inputs are assumed sorted under LC_ALL=C, which is what fstree.sh
# guarantees. comm and join both silently produce wrong output on unsorted
# input, so every use of them here re-sorts rather than trusting a caller two
# files away.
#
# Depends on utils.sh for libutils_die(). Source that first.
#
# Source-only. Not executable.

# ---------------------------------------------------------------------------
# Set comparison
# ---------------------------------------------------------------------------

# libcompare_only_in_first: write the lines present in the first listing only.
#
# $1 -- first listing
# $2 -- second listing
# $3 -- output file
#
# Prints the count on stdout so a caller can branch without reopening the file.
#
# Two one-sided files rather than one diff, because the two directions mean
# different things and get different treatment: present-in-baseline-only is
# something the rebuild lost, present-in-candidate-only is something it
# invented. Reading those apart off a diff's < and > markers is work the caller
# should not have to do.
libcompare_only_in_first() {
    local first="$1" second="$2" out="$3"

    [ -f "$first" ] || libutils_die "libcompare_only_in_first: no such file: $first"
    [ -f "$second" ] || libutils_die "libcompare_only_in_first: no such file: $second"

    LC_ALL=C comm -23 \
        <(LC_ALL=C sort "$first") \
        <(LC_ALL=C sort "$second") > "$out"

    wc -l < "$out" | tr -d ' '
}

# libcompare_only_in_second: write the lines present in the second listing only.
#
# $1 -- first listing
# $2 -- second listing
# $3 -- output file
#
# Prints the count on stdout.
libcompare_only_in_second() {
    local first="$1" second="$2" out="$3"

    [ -f "$first" ] || libutils_die "libcompare_only_in_second: no such file: $first"
    [ -f "$second" ] || libutils_die "libcompare_only_in_second: no such file: $second"

    LC_ALL=C comm -13 \
        <(LC_ALL=C sort "$first") \
        <(LC_ALL=C sort "$second") > "$out"

    wc -l < "$out" | tr -d ' '
}

# ---------------------------------------------------------------------------
# Permissions
# ---------------------------------------------------------------------------

# libcompare_mode_class: name the kind of cause a mode transition is consistent with.
#
# $1 -- octal mode in the first tree
# $2 -- octal mode in the second tree
#
# Prints one of:
#   umask     -- owner bits identical, difference confined to group/other.
#                This is what a differing umask does and all it can do: git
#                records only one permission bit per file (executable or not),
#                so every other bit is supplied by the umask in force when the
#                file was created. Such a difference did not come from the
#                content of either tree.
#   owner-exec-- the owner's execute bit differs. This one IS carried by git,
#                as the 100644/100755 distinction, so a difference here is a
#                real difference in what was committed -- a script that will
#                not run, or one that should not. Never dismissed as
#                systematic.
#   owner     -- some other owner bit differs (read or write). Not something a
#                umask does to files created the same way, so it wants looking
#                at individually.
#   other     -- anything left, including a mode that failed to parse.
#
# The classification is deliberately conservative: it says what a transition is
# *consistent with*, never what caused it. Two trees could differ in group bits
# for a reason other than umask, and the report is worded to leave that open.
libcompare_mode_class() {
    local a="$1" b="$2" a_owner b_owner a_rest b_rest

    case "$a$b" in
        *[^0-7]*) echo other; return 0 ;;
    esac

    # 10#$a forces base-10 reading of a string like "0644" that bash would
    # otherwise take as octal, which would make the arithmetic below silently
    # operate on the wrong number. The octal digits are then reassembled by
    # hand below rather than converted, so no numeric base conversion is
    # needed at all.
    a="$(printf '%04d' "$((10#$a))")"
    b="$(printf '%04d' "$((10#$b))")"

    [ "$a" != "$b" ] || { echo same; return 0; }

    a_owner="${a:1:1}"
    b_owner="${b:1:1}"
    a_rest="${a:0:1}${a:2:2}"
    b_rest="${b:0:1}${b:2:2}"

    if [ "$a_owner" = "$b_owner" ] && [ "$a_rest" != "$b_rest" ]; then
        echo umask
        return 0
    fi

    # Owner bits differ. Isolate the execute bit, because that is the only
    # permission bit git carries and therefore the only one whose difference
    # implicates the commit rather than the environment.
    if [ $(( a_owner & 1 )) -ne $(( b_owner & 1 )) ]; then
        echo owner-exec
        return 0
    fi

    echo owner
}

# libcompare_modes: write every mode difference, and a tally by transition.
#
# $1 -- modes listing for the first tree
# $2 -- modes listing for the second tree
# $3 -- output file for per-path differences
# $4 -- output file for the transition tally
#
# Per-path format: <type><TAB><mode a><TAB><mode b><TAB><path>
# Tally format:    <count><TAB><type><TAB><mode a><TAB><mode b><TAB><class>
#
# Prints the per-path difference count on stdout.
#
# Only paths present in both trees are considered. A path in one tree alone has
# no second mode to compare, and reporting it here as well as in the structure
# section would inflate the count of permission faults with what is really one
# missing file.
#
# join, not awk with an associative array: these trees run to over a million
# entries, and holding that many keys in awk costs hundreds of megabytes for a
# job two sorted streams do in constant memory.
libcompare_modes() {
    local first="$1" second="$2" out="$3" tally="$4"
    local tab keyed_first keyed_second

    [ -f "$first" ] || libutils_die "libcompare_modes: no such file: $first"
    [ -f "$second" ] || libutils_die "libcompare_modes: no such file: $second"

    tab=$(printf '\t')
    keyed_first="${out}.a"
    keyed_second="${out}.b"

    # Re-key from type-first to path-first. The listing is sorted by type, and
    # join needs both inputs sorted on the field it joins -- which must be the
    # path, because the path is what identifies the same entry across trees.
    awk -F'\t' '{print $3"\t"$1"\t"$2}' "$first" | LC_ALL=C sort -t "$tab" -k1,1 > "$keyed_first"
    awk -F'\t' '{print $3"\t"$1"\t"$2}' "$second" | LC_ALL=C sort -t "$tab" -k1,1 > "$keyed_second"

    # -o emits path, then each side's type and mode. An entry whose type
    # differs between trees is left to the structure section, which reports it
    # as a one-sided entry because type is part of that listing's key.
    LC_ALL=C join -t "$tab" -j 1 -o '0,1.2,1.3,2.2,2.3' "$keyed_first" "$keyed_second" \
        | awk -F'\t' '$3 != $5 { print $2"\t"$3"\t"$5"\t"$1 }' > "$out"

    rm -f "$keyed_first" "$keyed_second"

    # Classify each distinct transition once, not once per path: there are at
    # most a handful of transitions behind even a million differing files, and
    # libcompare_mode_class is a shell function whose per-call cost is real.
    : > "$tally"
    cut -f1,2,3 "$out" | LC_ALL=C sort | uniq -c \
        | while read -r count type mode_a mode_b; do
            printf '%s\t%s\t%s\t%s\t%s\n' \
                "$count" "$type" "$mode_a" "$mode_b" \
                "$(libcompare_mode_class "$mode_a" "$mode_b")" >> "$tally"
        done

    wc -l < "$out" | tr -d ' '
}

# libcompare_modes_unexplained: write the mode differences no systematic cause covers.
#
# $1 -- per-path differences written by libcompare_modes
# $2 -- transition tally written by libcompare_modes
# $3 -- output file
#
# Prints the count on stdout.
#
# This is the file an operator should read first. The umask-consistent
# transitions are summarised as counts elsewhere and deliberately not expanded:
# listing several thousand paths that all differ for one environmental reason
# is how the two or three that differ for a real reason go unnoticed.
libcompare_modes_unexplained() {
    local diffs="$1" tally="$2" out="$3" tab

    [ -f "$diffs" ] || libutils_die "libcompare_modes_unexplained: no such file: $diffs"
    [ -f "$tally" ] || libutils_die "libcompare_modes_unexplained: no such file: $tally"

    tab=$(printf '\t')

    # Build the set of transitions to exclude, then filter the per-path file
    # against it. Keyed on all three of type and both modes, so a transition
    # that is umask-consistent for directories does not accidentally excuse the
    # same octal pair appearing on a symlink.
    LC_ALL=C awk -F'\t' -v tab="$tab" '
        NR == FNR {
            if ($5 == "umask") explained[$2 tab $3 tab $4] = 1
            next
        }
        !( ($1 tab $2 tab $3) in explained )
    ' "$tally" "$diffs" > "$out"

    wc -l < "$out" | tr -d ' '
}

# ---------------------------------------------------------------------------
# Content
# ---------------------------------------------------------------------------

# libcompare_content: compare every file's bytes and write the differing paths.
#
# $1 -- first tree root
# $2 -- second tree root
# $3 -- output file for differing paths
# $4 -- output file for diff's raw output
#
# Prints the differing-file count on stdout.
#
# diff -qr, not a pair of checksum manifests. The precision is identical --
# both compare every byte -- but diff compares sizes first, stops at the first
# differing byte, and never hashes, so on a tree of this size it is the faster
# of the two for exactly the same answer. What it cannot do is leave behind a
# fingerprint to compare against a tree that is not present; that is a
# different job, and pretending one command does both is how a verification
# ends up doing neither well.
#
# --no-dereference makes a symlink compare as a symlink. Without it diff
# follows links and compares their targets, so a link pointing somewhere
# entirely different reads as identical whenever the two targets happen to
# match -- and a dangling link becomes a read error instead of a finding.
#
# Exit status is not checked: diff returns 1 for "differences found", which is
# this function's normal successful outcome, and 2 for trouble. Distinguishing
# them would mean treating an unreadable file as fatal, when the useful
# response is to report it in the raw output and carry on.
libcompare_content() {
    local first="$1" second="$2" out="$3" raw="$4"

    diff -qr --no-dereference -x .git -x .repo "$first" "$second" > "$raw" 2>&1 || true

    # Only the "differ" lines. diff also emits "Only in ..." for one-sided
    # entries, which the structure section already reports from the listings
    # with the entry's type attached -- keeping them here would double-count
    # every missing file.
    #
    # sed strips diff's sentence frame to leave the path as it appears under
    # the first tree, so this file's lines are paths and can be read alongside
    # every other listing. The prefix is removed separately, because the tree
    # root is not part of what identifies an entry within the tree.
    LC_ALL=C grep -E '^(Files|Symbolic links) .* differ$' "$raw" \
        | sed -e 's/^Files //' -e 's/^Symbolic links //' -e 's/ differ$//' \
        | sed -e "s| and ${second}/|\t|" \
        | cut -f1 \
        | sed -e "s|^${first}/||" \
        | LC_ALL=C sort > "$out"

    wc -l < "$out" | tr -d ' '
}

# libcompare_content_trouble: write the lines where diff reported a problem.
#
# $1 -- diff's raw output written by libcompare_content
# $2 -- output file
#
# Prints the count on stdout.
#
# An unreadable file, or a path that is a file in one tree and a directory in
# the other, means the comparison did not happen there. Silence about that
# would let a verification report "no content differences" for a file it never
# managed to read, which is the one failure mode a verification tool must not
# have.
libcompare_content_trouble() {
    local raw="$1" out="$2"

    [ -f "$raw" ] || libutils_die "libcompare_content_trouble: no such file: $raw"

    LC_ALL=C grep -vE '^(Files|Symbolic links) .* differ$' "$raw" \
        | LC_ALL=C grep -vE '^Only in ' > "$out" || true

    wc -l < "$out" | tr -d ' '
}
