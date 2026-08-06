# shellcheck shell=bash
#
# report.sh -- Build a plain-text report incrementally.
#
# No domain knowledge: nothing here knows what is being compared or what any
# finding means. It formats sections, tables and verdicts. What goes in them is
# the caller's business.
#
# Every function is named libreport_*, following the libs/ convention that a
# function's prefix names the file it lives in.
#
# WRITTEN INCREMENTALLY, and the summary written last: the summary states how
# many findings each section produced, and those counts are not known until
# every section has run. Buffering the whole report to reorder it would mean an
# interrupted run leaves nothing at all, on a job whose slowest phase takes
# minutes -- so sections are appended to a body file as they complete, and the
# summary is prepended when the run finishes.
#
# Plain text, not Markdown. This report is read in a terminal by someone
# deciding whether a sync is trustworthy; asterisks and pipe tables get in the
# way of that. It stays greppable, which matters more here than rendering.
#
# The report file is passed to every function rather than held in a global, so
# nothing here depends on initialisation order.
#
# Depends on utils.sh for libutils_die(). Source that first.
#
# Source-only. Not executable.

# libreport_begin: start a report body.
#
# $1 -- path to the body file to create
#
# Truncates. A re-run therefore produces a fresh report rather than appending
# to the previous one, where two runs' findings would sit under one summary and
# the older half would be read as current.
libreport_begin() {
    local body="$1"

    [ -n "$body" ] || libutils_die "libreport_begin: no body file given"
    : > "$body"
}

# libreport_section: start a numbered section.
#
# $1 -- body file
# $2 -- section number, as text ("1", "2")
# $3 -- title
libreport_section() {
    local body="$1" number="$2" title="$3"

    [ -f "$body" ] || libutils_die "libreport_section: $body does not exist (begin not called?)"

    {
        echo
        echo "============================================================================"
        echo "$number. $title"
        echo "============================================================================"
        echo
    } >> "$body"
}

# libreport_line: append one line verbatim.
#
# $1  -- body file
# $2+ -- text
libreport_line() {
    local body="$1"
    shift

    [ -f "$body" ] || libutils_die "libreport_line: $body does not exist (begin not called?)"
    echo "$*" >> "$body"
}

# libreport_verdict: append a section's PASS, FAIL or SKIP line.
#
# $1 -- body file
# $2 -- PASS, FAIL or SKIP
# $3 -- explanation
#
# Every section ends in one of these, so a reader scanning for "FAIL" finds
# every problem and can trust that the absence of the word means the checks
# actually ran and passed -- rather than that a section was skipped.
#
# SKIP exists so that last sentence stays true. A section that did not run is
# neither a pass nor a failure, and spelling it as either one lies: PASS claims
# a check that never happened, FAIL reports a problem nothing found. The word is
# rejected unless it is one of the three, because a typo'd verdict is a section
# whose result a reader's grep will never see.
libreport_verdict() {
    local body="$1" verdict="$2" text="$3"

    [ -f "$body" ] || libutils_die "libreport_verdict: $body does not exist (begin not called?)"

    case "$verdict" in
        PASS|FAIL|SKIP) ;;
        *) libutils_die "libreport_verdict: verdict must be PASS, FAIL or SKIP, got '$verdict'" ;;
    esac

    echo "[$verdict] $text" >> "$body"
}

# libreport_list: append a file's lines, indented, capped, with the cap declared.
#
# $1 -- body file
# $2 -- file whose lines to include
# $3 -- maximum number of lines to include; 0 for no limit
# $4 -- indent prefix
#
# When the cap truncates, the report says how many lines were withheld and
# where the complete list is. A silently truncated list reads as a complete
# one, which would turn "the first 200 of 5000 differences" into "there are 200
# differences" -- the exact misreading this whole tool exists to prevent.
libreport_list() {
    local body="$1" file="$2" limit="$3" indent="$4" total

    [ -f "$body" ] || libutils_die "libreport_list: $body does not exist (begin not called?)"

    if [ ! -f "$file" ]; then
        echo "${indent}(no data: $file was not produced)" >> "$body"
        return 0
    fi

    total=$(wc -l < "$file" | tr -d ' ')

    if [ "$total" -eq 0 ]; then
        return 0
    fi

    if [ "$limit" -gt 0 ] && [ "$total" -gt "$limit" ]; then
        head -n "$limit" "$file" | sed "s|^|${indent}|" >> "$body"
        echo "${indent}... $((total - limit)) more line(s) not shown; full list: $file" >> "$body"
    else
        sed "s|^|${indent}|" "$file" >> "$body"
    fi
}

# libreport_finish: prepend the header and summary, then move into place.
#
# $1 -- body file
# $2 -- final report path
# $3 -- header text block
# $4 -- summary text block
#
# The move is the commit point and is atomic within a filesystem, so the final
# report is either absent or complete. A half-written report that looks
# finished is worse than none: it would be read as a clean bill of health for
# checks that never ran.
libreport_finish() {
    local body="$1" final="$2" header="$3" summary="$4" part

    [ -f "$body" ] || libutils_die "libreport_finish: $body does not exist (begin not called?)"
    [ -n "$final" ] || libutils_die "libreport_finish: no destination given"

    part="${final}.part"

    {
        echo "$header"
        echo
        echo "$summary"
        cat "$body"
    } > "$part"

    mv "$part" "$final"
    rm -f "$body"
}
