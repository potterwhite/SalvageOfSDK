# shellcheck shell=bash
#
# fstree.sh -- Turn a directory tree into sorted, comparable listings.
#
# No domain knowledge: nothing here knows what an SDK is, that repo exists, or
# which of two trees is the baseline. It walks a directory and writes text
# files. Deciding what the differences mean belongs in compare.sh; deciding
# which trees to walk belongs in the caller.
#
# Every function is named libfstree_*, following the libs/ convention that a
# function's prefix names the file it lives in.
#
# Why listings-to-files rather than functions returning values: the trees this
# is built for hold hundreds of thousands of entries. Passing that through a
# shell variable is slow and, past ARG_MAX, simply fails. Files also survive
# the run, so an operator who distrusts the report can inspect the raw input
# it was computed from.
#
# THE EXCLUSION RULE, stated once because every function obeys it:
# entries named .git or .repo are pruned, along with everything under them.
# They hold version-control metadata, not tree content -- a freshly cloned
# tree and the tree it was cloned from have wildly different .git internals
# while being byte-identical in every file that matters. Comparing them would
# bury every real finding under noise. Nothing else is excluded: a build
# artefact left in one tree and not the other IS a difference, and hiding it
# would defeat the purpose.
#
# FIELD SEPARATOR: listings use a literal tab between fields, because a
# filename may legally contain spaces and a space-separated listing would
# misparse them. A filename containing a tab or a newline would still break
# these listings; libfstree_warn_odd_names exists to say so out loud rather
# than let the comparison quietly go wrong.
#
# SORT ORDER: every listing is sorted under LC_ALL=C. A locale-dependent sort
# would order the two listings differently on two machines, and diff would
# report differences that are really collation artefacts.
#
# Depends on utils.sh for libutils_die(). Source that first.
#
# Source-only. Not executable.

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------

# libfstree_require_dir: die unless the path is a readable directory.
#
# $1 -- path
# $2 -- role, used in the error message ("baseline", "candidate")
#
# Checked before any walking starts. A typo in a path would otherwise produce
# an empty listing, and an empty listing compared against a real one reports
# every single file as missing -- a catastrophic-looking report whose real
# cause is one wrong character.
libfstree_require_dir() {
    local dir="$1" role="$2"

    [ -n "$dir" ] || libutils_die "no $role directory given"
    [ -e "$dir" ] || libutils_die "$role directory does not exist: $dir"
    [ -d "$dir" ] || libutils_die "$role path is not a directory: $dir"
    [ -r "$dir" ] || libutils_die "$role directory is not readable: $dir"
}

# libfstree_abs: print the physical absolute path of a directory.
#
# $1 -- path
#
# Physical, so symlinked parent directories collapse to one spelling. Two
# arguments naming the same tree by different routes must be recognised as the
# same tree, and comparing a tree with itself is a mistake worth catching.
libfstree_abs() {
    local dir="$1"
    ( cd "$dir" && pwd -P )
}

# libfstree_warn_odd_names: warn if any entry name contains a tab or newline.
#
# $1 -- root
#
# These listings are line-oriented and tab-separated, so such a name corrupts
# them. Renaming vendor files is not an option here, so the honest response is
# to tell the operator the report may be wrong at those paths instead of
# presenting a clean-looking result computed from corrupt input.
#
# Detected by scanning NUL-delimited paths, not with find -name: a shell
# command substitution strips trailing newlines, so the obvious
# -name "*$(printf '\n')*" collapses to -name "*", matches every entry, and
# warns that the whole tree is unreliable. That false alarm is worse than no
# check, because an operator who sees it on every run learns to ignore the one
# time it is real.
libfstree_warn_odd_names() {
    local root="$1" plain nul

    # A path holding a tab or newline breaks the correspondence between NUL
    # records and lines, so these two counts disagree exactly when something is
    # wrong: -print0 emits one NUL per entry whatever the name contains, while
    # a newline inside a name adds a line to the -printf count.
    nul=$(find "$root" -mindepth 1 \( -name .git -o -name .repo \) -prune -o -print0 2>/dev/null \
        | tr -cd '\0' | wc -c | tr -d ' ')
    plain=$(find "$root" -mindepth 1 \( -name .git -o -name .repo \) -prune -o -printf '%p\n' 2>/dev/null \
        | wc -l | tr -d ' ')

    if [ "$nul" != "$plain" ]; then
        libutils_warn "$root: entry names contain a tab or newline ($nul entries, $plain lines); listings for those paths are unreliable"
    fi
}

# ---------------------------------------------------------------------------
# Listings
# ---------------------------------------------------------------------------

# libfstree_list_top: write the tree's immediate children.
#
# $1 -- root
# $2 -- output file
#
# Format: <type><TAB><name>[<TAB>-> <target>]
#
# Its own listing, separate from the full walk, because the top level is where
# a whole missing subtree shows up as a single line. In a full-tree diff the
# same fact appears as tens of thousands of missing-file lines with the one
# useful sentence buried among them.
#
# Symlink targets are included here and not in the other listings' equivalent,
# because at the top level a link is usually the entire point of the entry.
libfstree_list_top() {
    local root="$1" out="$2"

    find "$root" -mindepth 1 -maxdepth 1 \( -name .git -o -name .repo \) -prune -o \
        -type l -printf '%y\t%P\t-> %l\n' -o \
        -printf '%y\t%P\n' 2>/dev/null \
        | LC_ALL=C sort > "$out"
}

# libfstree_list_entries: write every entry with its type.
#
# $1 -- root
# $2 -- output file
#
# Format: <type><TAB><relative path>
#
# The type is part of the key, not extra detail. A path that is a regular file
# in one tree and a symlink in the other is a serious difference, and a
# path-only listing reports the two trees as identical there.
#
# %P yields the path relative to the root, which is what makes two listings
# from two different roots comparable at all.
libfstree_list_entries() {
    local root="$1" out="$2"

    find "$root" -mindepth 1 \( -name .git -o -name .repo \) -prune -o \
        -printf '%y\t%P\n' 2>/dev/null \
        | LC_ALL=C sort > "$out"
}

# libfstree_list_modes: write every entry's permission bits.
#
# $1 -- root
# $2 -- output file
#
# Format: <type><TAB><octal mode><TAB><relative path>
#
# Symlinks are included even though their own bits are not meaningful on Linux
# (always 777, and chmod on a link changes its target). Dropping them would
# make this listing's line count differ from the entries listing for no stated
# reason, and a reader comparing the two would have to work out why.
libfstree_list_modes() {
    local root="$1" out="$2"

    find "$root" -mindepth 1 \( -name .git -o -name .repo \) -prune -o \
        -printf '%y\t%m\t%P\n' 2>/dev/null \
        | LC_ALL=C sort > "$out"
}

# libfstree_list_links: write every symlink and the text of its target.
#
# $1 -- root
# $2 -- output file
#
# Format: <relative path><TAB>-> <target>
#
# The target is compared as text, deliberately unresolved. A link recorded as
# ../foo and a link recorded as /abs/path/foo may resolve to the same file
# today and diverge the moment the tree moves, so the two are not the same
# link and must not be reported as equal.
libfstree_list_links() {
    local root="$1" out="$2"

    find "$root" -mindepth 1 \( -name .git -o -name .repo \) -prune -o \
        -type l -printf '%P\t-> %l\n' 2>/dev/null \
        | LC_ALL=C sort > "$out"
}

# libfstree_list_empty_dirs: write every directory holding no entries.
#
# $1 -- root
# $2 -- output file
#
# Format: <relative path>
#
# Separate from the entries listing, which already contains these paths,
# because the cause is specific and the fix is specific: git has no way to
# represent an empty directory, so one present in a packaged tree is always
# absent from a clone of that tree. An operator reading "3000 entries missing"
# cannot act; one reading "these 39 directories are empty and git cannot carry
# them" can.
#
# A directory that is empty in one tree and populated in the other appears
# here as a one-sided entry, which is also worth seeing.
libfstree_list_empty_dirs() {
    local root="$1" out="$2"

    find "$root" -mindepth 1 \( -name .git -o -name .repo \) -prune -o \
        -type d -empty -printf '%P\n' 2>/dev/null \
        | LC_ALL=C sort > "$out"
}

# ---------------------------------------------------------------------------
# Survey
# ---------------------------------------------------------------------------
#
# These two answer a different question from the listings above. A listing is
# for comparing two trees; a survey is for looking at ONE tree and deciding
# what in it is worth keeping. That decision -- which files are build output or
# scratch and belong in a .gitignore -- cannot be made by a machine, because
# a stale .o and a shipped .o are the same bytes. It can only be made by
# someone who is shown what is there, before anything is committed.
#
# Before, not after, is the whole point: a large file that enters git history
# can only be removed by rewriting that history.

# libfstree_ext_histogram: print a per-extension tally with total sizes.
#
# $1 -- root
#
# Format: <count> <bytes> <extension>, largest total size first
#
# Sorted by total bytes rather than by count, because size is what decides
# whether something matters: 12000 .o files worth 1.2G is a finding, 12000
# .h files worth 4M is just a source tree.
#
# The extension is the text after the LAST dot of the basename, so
# linaro-bookworm-6.1-arm64.tar.xz counts as "xz". Files with no dot are
# reported as "(none)" -- which matters here, because compiled executables
# usually have no extension at all and would otherwise vanish from the table.
#
# Directories are not counted. A directory has no size of its own worth
# reporting, and libfstree_biggest is what shows a directory that is entirely
# scratch.
libfstree_ext_histogram() {
    local root="$1"

    libfstree_require_dir "$root" root

    # -type f only: a symlink's own size is the length of its target text,
    # which would be counted as if it were content.
    find "$root" -mindepth 1 \( -name .git -o -name .repo \) -prune -o \
        -type f -printf '%s\t%f\n' 2>/dev/null \
        | awk -F'\t' '
            {
                name = $2
                # No dot, or a leading dot with no other (".gitignore"), is
                # not an extension. Treating ".gitignore" as extension
                # "gitignore" would invent a file type that does not exist.
                if (match(name, /.+\./)) {
                    ext = substr(name, RLENGTH + 1)
                } else {
                    ext = "(none)"
                }
                count[ext]++
                bytes[ext] += $1
            }
            END { for (e in count) printf "%d\t%d\t%s\n", count[e], bytes[e], e }
        ' \
        | LC_ALL=C sort -t"$(printf '\t')" -k2,2nr
}

# libfstree_biggest: print the largest immediate children of a tree, with sizes.
#
# $1 -- root
# $2 -- how many to print
#
# Format: <bytes> <name>, largest first. Names are relative to the root, since
# the caller printed the root already and repeating it on every line pushes the
# sizes off the edge of a terminal.
#
# Immediate children only, and directories are totalled. This is what reveals
# a directory that is entirely build output -- buildroot's output/ being the
# case that matters -- which a per-file view cannot show: 40000 files of 30KB
# each look unremarkable one at a time and are 1.2G together.
libfstree_biggest() {
    local root="$1" limit="$2"

    libfstree_require_dir "$root" root

    case "$limit" in
        ''|*[!0-9]*) libutils_die "libfstree_biggest: count must be a number, got '$limit'" ;;
    esac

    # du, not find: only du totals a directory's contents.
    #
    # -k reports allocated blocks, which is what the disk actually holds and
    # what an operator comparing against `du -sh` will see. Multiplied to bytes
    # so both survey functions speak one unit and the caller formats once.
    du -sk "$root"/* 2>/dev/null \
        | LC_ALL=C sort -k1,1nr \
        | head -n "$limit" \
        | awk -F'\t' -v root="$root/" '{
            name = $2
            if (index(name, root) == 1) name = substr(name, length(root) + 1)
            printf "%d\t%s\n", $1 * 1024, name
          }'
}

# ---------------------------------------------------------------------------
# Summaries
# ---------------------------------------------------------------------------

# libfstree_count_types: print a per-type tally of an entries listing.
#
# $1 -- an entries listing written by libfstree_list_entries
#
# Format: <count> <type>
#
# Reads the listing rather than re-walking the tree. Walking an 18 GB tree
# twice to produce a number we already have on disk would double the slowest
# part of a run for nothing.
libfstree_count_types() {
    local listing="$1"

    [ -f "$listing" ] || libutils_die "libfstree_count_types: no such listing: $listing"

    cut -f1 "$listing" | LC_ALL=C sort | uniq -c | awk '{print $1" "$2}'
}

# libfstree_mode_histogram: print a per-type, per-mode tally of a modes listing.
#
# $1 -- a modes listing written by libfstree_list_modes
#
# Format: <count> <type> <mode>
#
# The histogram is what makes a tree-wide permission shift legible. Two
# histograms placed side by side show "every directory is 755 here and 775
# there" in eight lines; the underlying per-path diff shows the same fact in
# several thousand.
libfstree_mode_histogram() {
    local listing="$1"

    [ -f "$listing" ] || libutils_die "libfstree_mode_histogram: no such listing: $listing"

    cut -f1,2 "$listing" | LC_ALL=C sort | uniq -c \
        | awk -F'[ \t]+' '{print $2" "$3" "$4}'
}
