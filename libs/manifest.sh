# shellcheck shell=bash
#
# manifest.sh -- Write a repo manifest (default.xml) incrementally.
#
# Knows the manifest XML format and nothing else. It does not know what an SDK
# is, how subprojects are discovered, or that GitLab exists: callers supply
# already-computed paths and names, and this file turns them into XML.
#
# Its own file rather than part of gitrepo.sh, because gitrepo.sh is explicitly
# restricted to operations on the current working directory and forbids any
# knowledge of a larger tree. A manifest is the opposite: it exists precisely to
# record where each repository sits in a tree. Merging the two would break that
# restriction, which is the one thing keeping gitrepo.sh reusable.
#
# Written incrementally on purpose. Generating the whole file after every
# repository is built means a failure partway leaves no manifest at all, and the
# manifest is exactly the document needed to resume -- the directory-to-
# repository mapping is cheap to record as you go and expensive to reconstruct
# afterwards.
#
# Lifecycle, in order:
#   libmanifest_begin  <part> <fetch_base> <review_base> <branch>
#   libmanifest_append <part> <rel_path> <repo_name>     (once per finished item)
#   libmanifest_finish <part> <final>
#
# The part file is passed to every function rather than held in a global, so
# nothing here depends on initialisation order and two manifests can be written
# in one run if that is ever needed.
#
# Depends on utils.sh for libutils_die(). Source that first.
#
# Source-only. Not executable.

# libmanifest_xml_escape: print a string safe to place in an XML attribute.
#
# $1 -- raw text
#
# '&' must be substituted first: doing it after the others would re-escape the
# ampersands those substitutions just introduced, turning < into &amp;lt;.
#
# Paths and repository names from a vendor tree are not guaranteed to be free of
# these characters, and an unescaped one produces a default.xml that every XML
# parser rejects -- reported by `repo init` as a generic parse failure that says
# nothing about which path caused it.
libmanifest_xml_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    echo "$s"
}

# libmanifest_begin: start a manifest by writing its header.
#
# $1 -- path to the .part file to create
# $2 -- remote fetch base URL, with a trailing slash
# $3 -- default revision (branch name)
#
# Truncates the part file. A re-run therefore rebuilds the list from scratch and
# no entry can appear twice; appending to an existing manifest would need a
# dedup pass, and a dedup pass is a second place for the naming rule to live.
#
# No review= attribute is written: it names a Gerrit server, is read only by
# `repo upload`, and we host on GitLab. Emitting one pointed at the GitLab URL
# advertised a review system that does not exist.
libmanifest_begin() {
    local part="$1" fetch="$2" branch="$3"

    [ -n "$part" ] || libutils_die "libmanifest_begin: no part file given"

    cat > "$part" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remote name="origin" fetch="$(libmanifest_xml_escape "$fetch")" />
  <default revision="$(libmanifest_xml_escape "$branch")" remote="origin" sync-j="4" />

EOF
}

# libmanifest_line: print one project element, without writing it anywhere.
#
# $1 -- project path, relative to the tree root
# $2 -- repository name, without the .git suffix
#
# Split out from libmanifest_append so that a caller adopting a single directory
# can print the line for review instead of appending it to a file. Both go
# through here, which is the point: two formatters would eventually disagree
# about escaping or attribute order, and the file they both write is the one
# every clone of this SDK depends on.
libmanifest_line() {
    local rel="$1" repo_name="$2"

    [ -n "$rel" ] || libutils_die "libmanifest_line: empty project path"
    [ -n "$repo_name" ] || libutils_die "libmanifest_line: empty repository name for '$rel'"

    # An absolute path yields a manifest that only works on the machine that
    # generated it, so it is rejected rather than silently written.
    case "$rel" in
        /*) libutils_die "libmanifest_line: project path must be relative, got '$rel'" ;;
    esac

    printf '  <project path="%s" name="%s.git" />\n' \
        "$(libmanifest_xml_escape "$rel")" \
        "$(libmanifest_xml_escape "$repo_name")"
}

# libmanifest_append: record one finished project.
#
# $1 -- path to the .part file
# $2 -- project path, relative to the tree root
# $3 -- repository name, without the .git suffix
#
# Callers must invoke this only after that project's work has actually
# succeeded. A line here means "done"; writing it beforehand would turn the
# manifest from a record into a prediction.
libmanifest_append() {
    local part="$1" rel="$2" repo_name="$3"

    [ -f "$part" ] || libutils_die "libmanifest_append: $part does not exist (begin not called?)"

    libmanifest_line "$rel" "$repo_name" >> "$part"
}

# libmanifest_finish: close the manifest and move it into place atomically.
#
# $1 -- path to the .part file
# $2 -- final path to move it to
#
# The closing tag is written last, so until this runs the part file is
# deliberately unparseable: repo cannot be pointed at a half-written manifest
# and told to sync, which is the correct outcome for a run that never finished.
#
# The mv is the commit point, and it is atomic within a filesystem. The final
# file is therefore either absent or complete -- never a truncated file that
# looks usable.
libmanifest_finish() {
    local part="$1" final="$2"

    [ -f "$part" ] || libutils_die "libmanifest_finish: $part does not exist (begin not called?)"
    [ -n "$final" ] || libutils_die "libmanifest_finish: no destination given"

    echo "</manifest>" >> "$part"
    mv "$part" "$final"
}

# libmanifest_count: print how many projects a manifest or part file records.
#
# $1 -- path to a manifest or .part file
#
# Counts <project lines rather than parsing XML, which is sufficient because
# this file only ever reads manifests it wrote itself. Prints 0 for a missing
# file so a caller can report progress without first checking existence.
libmanifest_count() {
    local file="$1"

    [ -f "$file" ] || { echo 0; return 0; }
    grep -c '<project ' "$file" 2>/dev/null || echo 0
}
