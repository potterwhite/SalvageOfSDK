# shellcheck shell=bash
#
# extras.sh -- Filesystem state that git cannot carry, recorded and replayed.
#
# Two kinds of state, one cause. A git commit stores a path, its bytes, and a
# single permission bit -- the owner execute bit. It stores nothing else about
# the filesystem. So a tree packaged by a vendor and a tree produced by cloning
# that same content differ in exactly two ways that no amount of correct
# committing can fix:
#
#   1. An empty directory. Git has no object type for one. A directory with no
#      entries cannot be committed, so it cannot be checked out.
#
#   2. Group and other permission bits. Absent from the commit, they are
#      supplied by the umask of the shell that ran the checkout. A tree
#      packaged with 775 directories arrives as 755 under umask 022 and as 775
#      under umask 002 -- and a tree that mixes both, as this SDK's does,
#      cannot be reproduced by any single umask.
#
# Neither is a defect to be fixed in the rebuild. Both are limits of the
# format. The only way to close them is to record the state from the original
# tree, ship the record, and replay it after checkout -- which is what this
# library does.
#
# It deliberately does NOT record ownership. uid and gid are properties of the
# machine that unpacked the vendor archive, not of the SDK, and replaying them
# needs root. A colleague's tree owned by that colleague is correct.
#
# Nor does it record symlink modes. A symlink's own mode is unused on Linux --
# permission checks follow the target -- and chmod without -h changes the
# target instead, which is worse than doing nothing.
#
# Every function is named libextras_*, following the libs/ convention that a
# function's prefix names the file it lives in.
#
# Source-only. Not executable.

# ---------------------------------------------------------------------------
# The canonical mode
# ---------------------------------------------------------------------------
#
# What a checkout produces under umask 022, which is the only mode information
# a commit can round-trip:
#
#   directory                    755
#   file with owner execute      755
#   file without owner execute   644
#
# A record is written for every entry that differs. Nothing else needs one:
# those three are exactly reproducible from the commit plus a known umask, so
# storing them would be storing 188000 lines to say "as expected".
#
# The comparison is against the full mode string, not the low nine bits, so a
# setuid or sticky entry reads as an exception and is preserved. That is the
# intent -- those bits are not in the commit either.

LIBEXTRAS_DIR_MODE=755
LIBEXTRAS_EXEC_MODE=755
LIBEXTRAS_FILE_MODE=644

# ---------------------------------------------------------------------------
# The record file
# ---------------------------------------------------------------------------
#
# One text file, TAB-separated, two record kinds:
#
#   dir<TAB><relative path>
#   mode<TAB><octal><TAB><relative path>
#
# Text and line-oriented because it is committed to the manifest repository
# alongside default.xml, where its diff is the review: a reviewer can see that
# a regenerated record added three directories, which is not true of any binary
# or serialised form.
#
# Directory records come first and are applied first. A recorded empty
# directory may also carry a recorded mode, and it has to exist before it can
# be chmod'd.
#
# Sorted with LC_ALL=C so that regenerating the record from an unchanged tree
# produces a byte-identical file. A record whose line order drifted between
# runs would show spurious diffs and train reviewers to skip them.

# libextras_record: write the record for one tree.
#
# $1 -- root of the tree to read
# $2 -- source label for the header comment, e.g. the baseline path
#
# Writes to stdout. The caller redirects. That keeps the result separable from
# the narration, in the way the rest of this toolkit does, and means a record
# can be diffed against an existing one without a temporary file:
#
#     carry-extras.sh --record --dir=<baseline> | diff - extras.txt
#
# Reads only. Nothing under $1 is modified, which is what lets it run against
# the read-only pristine tree that is the whole point of having a baseline.
libextras_record() {
    local root="$1" label="$2"

    cat <<EOF
# extras.txt -- filesystem state git cannot carry.
#
# Recorded from: ${label}
#
# Regenerate; do not edit by hand:
#     carry-extras.sh --record --dir=<original tree> > extras.txt
#
# Replay after a sync:
#     carry-extras.sh --apply --dir=<workspace> --file=extras.txt
#
# Format, TAB-separated:
#   dir <path>            an empty directory, which git cannot commit
#   mode <octal> <path>   a mode git cannot store (it keeps owner execute only)
#
# Paths are relative to the tree root. .git and .repo are excluded.
EOF

    # Directories first: see the note above on apply order.
    find "$root" -mindepth 1 \( -name .git -o -name .repo \) -prune -o \
        -type d -empty -printf 'dir\t%P\n' 2>/dev/null \
        | LC_ALL=C sort

    # -printf '%y\t%m\t%P' rather than three finds, so the type and the mode
    # come from one stat of one entry. Two passes could disagree about an entry
    # that changed between them; on a tree being recorded that should not
    # happen, and a format that cannot express the disagreement is better than
    # a comment asking the reader to assume it did not.
    find "$root" -mindepth 1 \( -name .git -o -name .repo \) -prune -o \
        \( -type d -o -type f \) -printf '%y\t%m\t%P\n' 2>/dev/null \
        | awk -F'\t' -v d="$LIBEXTRAS_DIR_MODE" \
                     -v x="$LIBEXTRAS_EXEC_MODE" \
                     -v f="$LIBEXTRAS_FILE_MODE" '
            # Skip the three modes a checkout reproduces on its own. A file is
            # canonically 755 or 644 according to its owner execute bit, which
            # is the one bit the commit does carry -- so testing the mode alone
            # is enough: a file at 755 has that bit and is right, a file at 644
            # lacks it and is also right. Anything else is an exception.
            $1 == "d" && $2 == d { next }
            $1 == "f" && $2 == x { next }
            $1 == "f" && $2 == f { next }
            { print "mode\t" $2 "\t" $3 }
        ' \
        | LC_ALL=C sort -t'	' -k3
}

# libextras_count: print how many records of one kind a file holds.
#
# $1 -- record file
# $2 -- kind, "dir" or "mode"
#
# Comment and blank lines are not records and are not counted. The count is
# what an operator checks the record against ("39 directories, as the
# verification report said"), so it has to mean records and not lines.
libextras_count() {
    local file="$1" kind="$2"
    grep -c "^${kind}	" "$file" 2>/dev/null || true
}

# libextras_validate: die unless every line of the record file parses.
#
# $1 -- record file
#
# Run before anything is changed. A record file is generated, but it is also
# committed, merged and occasionally hand-edited against advice, and a line
# this library does not understand must stop the run rather than be skipped:
# skipping means a directory silently not created, which surfaces later as a
# build failure with no connection to this tool.
#
# A mode is checked for being three or four octal digits rather than being fed
# to chmod to see what happens. chmod accepts symbolic modes like u+x, which
# would apply something other than what the record appears to say.
libextras_validate() {
    local file="$1" line n=0 bad=0

    [ -f "$file" ] || libutils_die "no such record file: $file"
    [ -r "$file" ] || libutils_die "record file is not readable: $file"

    while IFS= read -r line; do
        n=$((n + 1))
        case "$line" in
            '#'*|'') continue ;;
        esac

        case "$line" in
            dir$'\t'?*)
                ;;
            mode$'\t'?*$'\t'?*)
                local mode="${line#mode$'\t'}"
                mode="${mode%%$'\t'*}"
                case "$mode" in
                    [0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) ;;
                    *)
                        libutils_warn "$file:$n: not an octal mode: '$mode'"
                        bad=$((bad + 1))
                        ;;
                esac
                ;;
            *)
                libutils_warn "$file:$n: unrecognised record: $line"
                bad=$((bad + 1))
                ;;
        esac
    done < "$file"

    [ "$bad" -eq 0 ] || libutils_die "$file: $bad unusable line(s); nothing applied"
}

# ---------------------------------------------------------------------------
# Replay
# ---------------------------------------------------------------------------

# libextras_normalize: set every entry under a tree to its canonical mode.
#
# $1 -- root of the tree to change
#
# Run before the recorded exceptions, and the reason it exists at all is that
# the alternative is asking every colleague to set umask 022 before syncing.
# That instruction is one line in a document and is forgotten, and forgetting
# it produces a tree whose every file differs from the original -- a
# verification report with 187000 findings, none of them real.
#
# Normalising makes the result independent of whoever ran the sync and of what
# their shell's umask happened to be. It is also idempotent: running it twice
# changes nothing the second time.
#
# .git and .repo are pruned, and not as tidiness. Git writes loose objects
# read-only on purpose; chmod'ing them to 644 tells git it may rewrite an
# object it is entitled to assume is immutable.
#
# The owner execute bit is read, never written blind: a file that has it keeps
# it, one that lacks it does not gain it. That bit IS in the commit, so the
# checkout already has it right, and overwriting it would replace correct
# information with a guess.
libextras_normalize() {
    local root="$1"

    find "$root" -mindepth 1 \( -name .git -o -name .repo \) -prune -o \
        -type d -exec chmod "$LIBEXTRAS_DIR_MODE" {} +

    find "$root" -mindepth 1 \( -name .git -o -name .repo \) -prune -o \
        -type f -perm -u=x -exec chmod "$LIBEXTRAS_EXEC_MODE" {} +

    find "$root" -mindepth 1 \( -name .git -o -name .repo \) -prune -o \
        -type f ! -perm -u=x -exec chmod "$LIBEXTRAS_FILE_MODE" {} +
}

# libextras_apply_dirs: create the recorded empty directories.
#
# $1 -- record file
# $2 -- root of the tree to change
# $3 -- "yes" to report only and change nothing
#
# Prints one line per action to stderr and a tally to stdout as
# "<created> <existed> <occupied>".
#
# An "occupied" directory -- recorded as empty, present with content -- is
# reported rather than emptied. It means the two trees genuinely disagree about
# what belongs there, which is a finding for the operator and not something to
# resolve by deleting a colleague's files.
libextras_apply_dirs() {
    local file="$1" root="$2" dry="$3"
    local line path created=0 existed=0 occupied=0

    while IFS= read -r line; do
        case "$line" in
            dir$'\t'*) path="${line#dir$'\t'}" ;;
            *) continue ;;
        esac

        if [ -d "$root/$path" ]; then
            if [ -n "$(ls -A "$root/$path" 2>/dev/null)" ]; then
                libutils_warn "recorded as empty but holds content: $path"
                occupied=$((occupied + 1))
            else
                existed=$((existed + 1))
            fi
            continue
        fi

        if [ -e "$root/$path" ] || [ -L "$root/$path" ]; then
            libutils_warn "recorded as an empty directory but exists as something else: $path"
            occupied=$((occupied + 1))
            continue
        fi

        [ "$dry" = yes ] || mkdir -p "$root/$path"
        created=$((created + 1))
    done < "$file"

    echo "$created $existed $occupied"
}

# libextras_apply_modes: restore the recorded modes.
#
# $1 -- record file
# $2 -- root of the tree to change
# $3 -- "yes" to report only and change nothing
#
# Prints a tally to stdout as "<applied> <missing>".
#
# A missing path is reported, not fatal. It is the expected outcome for
# anything a .gitignore in the rebuild excluded: the mode cannot be restored
# because the file was never committed. Treating that as an error would make
# this tool refuse to do the part of its job it can still do, and the count is
# more useful than the refusal -- it is an independent measure of how much
# content the rebuild is still missing.
#
# Records are applied deepest-first. Reversing an LC_ALL=C sort puts a child
# before its parent, so a recorded mode that removes write permission from a
# directory is applied after the entries inside it have been dealt with.
libextras_apply_modes() {
    local file="$1" root="$2" dry="$3"
    local line rest mode path applied=0 missing=0

    while IFS= read -r line; do
        case "$line" in
            mode$'\t'*) rest="${line#mode$'\t'}" ;;
            *) continue ;;
        esac
        mode="${rest%%$'\t'*}"
        path="${rest#*$'\t'}"

        # -e follows symlinks, so a dangling one would read as missing. -L
        # catches it, and a recorded mode on a symlink is skipped rather than
        # applied, because chmod without -h would change the target instead.
        if [ -L "$root/$path" ]; then
            continue
        fi
        if [ ! -e "$root/$path" ]; then
            missing=$((missing + 1))
            continue
        fi

        [ "$dry" = yes ] || chmod "$mode" "$root/$path"
        applied=$((applied + 1))
    done < <(LC_ALL=C sort -r "$file")

    echo "$applied $missing"
}

# ---------------------------------------------------------------------------
# The hook bundle
# ---------------------------------------------------------------------------
#
# Four things have to sit together in one git repository for repo to run this
# automatically. The shape is forced by how repo finds a hook: it joins the
# hooks project's worktree with the hook name plus ".py" (hooks.py,
# _script_fullpath). So post-sync.py must be at that project's root, and
# everything it needs must be reachable from there.
#
#   post-sync.py     the entry point repo executes; its name is not a choice
#   carry-extras.sh  what actually does the work
#   libs/            the three libraries that script sources
#   extras.txt       the record, generated from the baseline
#
# It has to be its own repository. repo's own documentation is explicit that the
# hooks project is a separate repo referenced by name, not a subdirectory of
# something else -- and the path join above is why: a subdirectory has no
# project name for in-project to point at.

# libextras_bundle_write: assemble the four files in a directory.
#
# $1 -- root of this toolkit (the directory holding 5-fixtools/ and libs/)
# $2 -- directory to assemble into; created if absent
# $3 -- baseline tree to record from
#
# The record is generated last. It is the only part that can legitimately fail
# -- a wrong --baseline-dir -- and leaving the copies before it means a failure
# is visible as a bundle with no extras.txt rather than as a half-copied one.
#
# Only the three libraries carry-extras.sh sources are copied. Taking all of
# libs/ would put gitlab.sh, which handles access tokens, into a repository
# whose entire purpose is to be cloned by everyone who syncs the SDK. It leaks
# nothing by itself, but a file with no reason to be there is a file nobody
# audits.
libextras_bundle_write() {
    local from="$1" to="$2" baseline="$3"

    mkdir -p "$to/libs"

    cp "$from/5-fixtools/post-sync.py" "$to/post-sync.py"
    cp "$from/5-fixtools/carry-extras.sh" "$to/carry-extras.sh"
    chmod 755 "$to/carry-extras.sh"

    cp "$from/libs/utils.sh" "$to/libs/utils.sh"
    cp "$from/libs/args.sh" "$to/libs/args.sh"
    cp "$from/libs/extras.sh" "$to/libs/extras.sh"

    libextras_record "$baseline" "$baseline" > "$to/extras.txt"
}

# libextras_manifest_lines: print the two lines to paste into default.xml.
#
# $1 -- the hooks project's name on the server, without any .git suffix
#
# Printed rather than written, for the reason adopt-dir.sh gives: editing
# default.xml by machine means rewriting the XML every clone of this SDK depends
# on, and the paste is the one moment a human looks at what will be added.
#
# Both elements are self-closing and carry no children. repo's parser reads
# in-project and enabled-list and never walks below the node, so the <hook>
# child element some examples show is silently ignored -- and a non-self-closing
# element here is the mistake that once turned <linkfile> entries into stray
# top-level siblings repo quietly skipped.
# The checkout path is .hooks and not .repo-hooks: manifest_xml.py rejects any
# path component starting with ".repo", which repo reserves for its own .repo/
# directory, with 'bad component: .repo-hooks' at repo init time.
#
# The .git suffix is appended here rather than carried in $1 because libs/gitlab.sh
# appends it too when it builds the clone and push URLs. One bare name, both
# consumers adding the suffix themselves.
libextras_manifest_lines() {
    local name="$1"
    echo "  <project path=\".hooks\" name=\"${name}.git\" />"
    echo "  <repo-hooks in-project=\"${name}.git\" enabled-list=\"post-sync\" />"
}
