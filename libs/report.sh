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
# BUILT IN A FILE, PRINTED AT THE END, and the summary written last: the summary
# states how many findings each section produced, and those counts are not known
# until every section has run. So sections are appended to a body file as they
# complete, and the whole thing -- header, summary, body -- is printed once the
# run finishes.
#
# The body file is why the summary can be at the top of a stream that has to be
# written in order. It is not a cache and not an output: nothing reads it but
# libreport_emit, which deletes it.
#
# The report is printed to stdout, not written to a path this library chooses.
# Where it ends up is the caller's shell's business -- '>', '>>', '| less' --
# and offering an option for that would reimplement, worse, what the shell
# already does.
#
# Plain text, not Markdown. This report is read in a terminal by someone
# deciding whether a sync is trustworthy; asterisks and pipe tables get in the
# way of that. It stays greppable, which matters more here than rendering.
#
# The body file is passed to every function rather than held in a global, so
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
# $5 -- optional: text naming where the withheld lines can be read.
#       Empty or absent names the file itself.
#
# When the cap truncates, the report says how many lines were withheld and
# where the complete list is. A silently truncated list reads as a complete
# one, which would turn "the first 200 of 5000 differences" into "there are 200
# differences" -- the exact misreading this whole tool exists to prevent.
#
# $5 exists because the file is not always still there to be read. A caller
# whose working files are a throwaway temporary directory must be able to say
# so, rather than print the path of something already deleted -- a reader who
# goes looking for it and finds nothing learns only that the tool lies.
libreport_list() {
    local body="$1" file="$2" limit="$3" indent="$4" where="${5:-}" total

    [ -f "$body" ] || libutils_die "libreport_list: $body does not exist (begin not called?)"
    [ -n "$where" ] || where="full list: $file"

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
        echo "${indent}... $((total - limit)) more line(s) not shown; ${where}" >> "$body"
    else
        sed "s|^|${indent}|" "$file" >> "$body"
    fi
}

# libreport_emit: print the header, the summary and the body, in that order.
#
# $1 -- body file
# $2 -- header text block
# $3 -- summary text block
#
# To stdout, so the caller's shell decides where the report goes: to a terminal,
# to a file with '>', appended with '>>', or into a pipe. A function that opened
# its own output file would be able to do only the first two, and would need an
# option to say which.
#
# Nothing is atomic here, and nothing can be: a stream is visible as it is
# written. The guarantee an output file gave -- absent or complete, never
# half-written and mistaken for finished -- is replaced by the exit status,
# which the caller must check. Removing the body last means a run that dies
# mid-print leaves no stale body for the next one to append to.
libreport_emit() {
    local body="$1" header="$2" summary="$3"

    [ -f "$body" ] || libutils_die "libreport_emit: $body does not exist (begin not called?)"

    echo "$header"
    echo
    echo "$summary"
    cat "$body"

    rm -f "$body"
}
