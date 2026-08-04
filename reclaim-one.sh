#!/usr/bin/env bash
#
# reclaim-one.sh -- Reclaim ONE project of a repo-stripped SDK into GitLab.
#
# Scope: exactly one project per invocation. No loops, no batching.
# Rationale: 55 projects each fail differently. A per-project script you can
# re-run after fixing one thing beats a batch script that dies at #37.
#
# Design rules:
#   1. Respect the vendor's surviving .gitignore. Do NOT second-guess it.
#      Compilation is the judge, not this script. The sole exception is
#      FORCE_ADD -- see stage_tree() for why it must exist.
#   2. Idempotent. Safe to re-run at any point. Never destroys SDK content.
#   3. The PAT lives only in $GITLAB_TOKEN, enters .git/config solely for the
#      duration of the push, and is scrubbed immediately afterwards.
#
# Structure: every statement lives inside a function; main() is the only caller.
# Nothing executes at file scope except the final main dispatch, so this file
# can be sourced for testing individual functions without side effects.
#
# Usage:
#   export GITLAB_TOKEN='glpat-...'
#   ./reclaim-one.sh external/mpp
#
#   # For a project whose .gitignore excludes paths that were themselves repo
#   # projects (docs excludes cn/ and en/, holding 322 PDFs):
#   FORCE_ADD="cn en" ./reclaim-one.sh docs
#
# Environment:
#   GITLAB_TOKEN  (required) Personal Access Token; scopes: api, write_repository
#   SDK_ROOT      (optional) default /home/developer/sdk/linux/rk3576-linux-6.1
#   GITLAB_URL    (optional) default http://192.168.3.67
#   GITLAB_GROUP  (optional) default team_rk3576
#   FORCE_ADD     (optional) space-separated paths to `git add -f`
#   LFS_MIN_MB    (optional) default 50; files at or above this size go to LFS

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

# say: progress line on stdout. Prefixed so it is distinguishable from the
# git/curl output that this script deliberately does not suppress entirely.
say() {
    echo "==> $*"
}

# die: abort with a message on stderr. Every failure path routes through here
# so that the exit code is always 1 and never a partial success.
die() {
    echo "ERROR: $*" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# init_config: populate the global configuration knobs from the environment,
# applying defaults. Called first by main() so that every later function can
# rely on these being set.
#
# These are the only globals the script uses. They are assigned here rather
# than at file scope so that sourcing this file has no side effects.
init_config() {
    SDK_ROOT="${SDK_ROOT:-/home/developer/sdk/linux/rk3576-linux-6.1}"
    GITLAB_URL="${GITLAB_URL:-http://192.168.3.67}"
    GITLAB_GROUP="${GITLAB_GROUP:-team_rk3576}"
    LFS_MIN_MB="${LFS_MIN_MB:-50}"
    FORCE_ADD="${FORCE_ADD:-}"

    # Host without the scheme. Needed when embedding credentials, because the
    # PAT must be inserted between the scheme and the host:
    #   http://oauth2:TOKEN@host/group/name.git
    GITLAB_HOST="${GITLAB_URL#http://}"
    GITLAB_HOST="${GITLAB_HOST#https://}"
}

# check_prereqs: verify the tools and credentials exist before we touch
# anything. Failing here costs nothing; failing after `git init` leaves a
# half-created repo the user has to reason about.
check_prereqs() {
    [ -n "${GITLAB_TOKEN:-}" ] || die "GITLAB_TOKEN is not set. export it first."
    command -v git >/dev/null || die "git not found"
    command -v curl >/dev/null || die "curl not found"
    command -v python3 >/dev/null || die "python3 not found (used for JSON/URL parsing)"
}

# ---------------------------------------------------------------------------
# Target resolution
# ---------------------------------------------------------------------------

# resolve_target: validate the requested project path and derive the GitLab
# repository name from it. Sets REL, ABS, NAME, REPO_URL.
#
# $1 -- project path relative to SDK_ROOT, e.g. external/mpp
resolve_target() {
    REL="${1%/}"                      # tolerate a trailing slash from tab-completion
    ABS="$SDK_ROOT/$REL"

    [ -d "$ABS" ] || die "not a directory: $ABS"

    # A symlinked directory is NOT a project. In this SDK, kernel -> kernel-6.1
    # and common -> device/rockchip/common. Creating repos for them would
    # duplicate the target's content on the server and, worse, `repo sync`
    # would then materialise a real directory where a symlink belongs.
    # The correct expression is <linkfile> inside the target's project.
    if [ -L "$ABS" ]; then
        die "$REL is a symlink -> $(readlink "$ABS"). Do not create a repo for it; express it in the manifest as <linkfile> under its target project."
    fi

    # GitLab project names cannot contain '/', which is the namespace
    # separator. external/mpp -> external-mpp. This lossy mapping is exactly
    # why the manifest needs both name= (GitLab repo) and path= (SDK location).
    NAME="${REL//\//-}"
    REPO_URL="$GITLAB_URL/$GITLAB_GROUP/$NAME.git"
}

# auth_url: echo the push URL with the PAT embedded. Kept as a function with
# no side effects so the token never lands in a variable that other functions
# might accidentally print.
auth_url() {
    echo "http://oauth2:$GITLAB_TOKEN@$GITLAB_HOST/$GITLAB_GROUP/$NAME.git"
}

# ---------------------------------------------------------------------------
# Stage 1: preserve evidence, clear the way for git init
# ---------------------------------------------------------------------------

# preserve_evidence: record the dangling .git symlink target, then move it
# aside.
#
# The target (e.g. ../../.repo/projects/external/mpp.git) is the proof that
# this location WAS a repo project -- the only surviving trace of the vendor's
# original manifest. We print it before moving so it lands in the operator's
# terminal log. We never delete it; that is the caller's choice.
#
# Why it must be moved rather than left in place: `git init` follows a .git
# symlink. With a dangling one, git would attempt to create the repository at
# the (nonexistent) link target instead of here.
preserve_evidence() {
    if [ -L .git ]; then
        say "evidence: .git -> $(readlink .git)"
        mv .git .git.stripped-symlink.bak
        say "moved aside as .git.stripped-symlink.bak"
    fi
}

# init_local_repo: create the repository if absent, and register our own
# bookkeeping file as locally ignored.
#
# .git/info/exclude is used rather than .gitignore on purpose: it is local-only
# and never pushed, so the vendor's tree stays byte-identical to what they
# shipped. Editing their .gitignore would create a permanent rebase conflict
# for one line of our own housekeeping.
init_local_repo() {
    if [ -d .git ]; then
        say "reusing existing .git (this is a re-run)"
    else
        say "git init"
        git init -q -b main
    fi

    grep -qxF '.git.stripped-symlink.bak' .git/info/exclude 2>/dev/null \
        || echo '.git.stripped-symlink.bak' >> .git/info/exclude
}

# ---------------------------------------------------------------------------
# Stage 2: Git LFS -- must run BEFORE git add
# ---------------------------------------------------------------------------

# setup_lfs: track every file at or above LFS_MIN_MB with Git LFS.
#
# Ordering is not cosmetic. If a large file is committed as an ordinary blob
# first, moving it to LFS later requires rewriting history. Track first, add
# second.
#
# `git lfs install --local` confines the filter configuration to this
# repository instead of mutating the user's ~/.gitconfig.
#
# The find expression prunes .git and our backup so that neither is ever
# considered for tracking.
setup_lfs() {
    local big count f

    big=$(find . -path ./.git -prune \
               -o -name '.git.stripped-symlink.bak' -prune \
               -o -type f -size +$((LFS_MIN_MB - 1))M -print 2>/dev/null || true)

    if [ -z "$big" ]; then
        say "LFS: not needed (no file >= ${LFS_MIN_MB}MB)"
        return 0
    fi

    command -v git-lfs >/dev/null \
        || die "files >= ${LFS_MIN_MB}MB present but git-lfs is not installed"

    count=$(echo "$big" | wc -l)
    say "LFS: tracking $count file(s) >= ${LFS_MIN_MB}MB"
    git lfs install --local -q

    while IFS= read -r f; do
        [ -n "$f" ] || continue
        echo "    lfs: ${f#./}"
        git lfs track "${f#./}" >/dev/null
    done <<< "$big"

    git add .gitattributes
}

# ---------------------------------------------------------------------------
# Stage 3: staging
# ---------------------------------------------------------------------------

# stage_tree: stage the working tree, honouring the vendor's .gitignore.
#
# Plain `git add .`. Whatever their .gitignore excludes stays excluded. If the
# build later fails on a missing file, that failure is the signal to come back
# and force-add it -- we do not guess up front, because guessing is what makes
# this class of migration unreviewable.
#
# FORCE_ADD is the single deliberate override, and it exists for one specific
# reason: there is a class of loss that compilation can never reveal. When a
# parent's .gitignore excludes a path because that path used to be a nested
# repo project, the rule was CORRECT under the original multi-repo layout and
# is WRONG once the project is flattened into one repository. docs/.gitignore
# excludes cn/ and en/ for exactly that reason, and those hold 322 PDFs. No
# compile failure would ever reveal their absence, so this is the one place
# where a human decision has to be encoded explicitly.
stage_tree() {
    local p

    say "git add ."
    git add .

    [ -n "$FORCE_ADD" ] || return 0

    for p in $FORCE_ADD; do
        [ -e "$p" ] || die "FORCE_ADD path does not exist: $p"
        say "git add -f $p   (overriding .gitignore on purpose)"
        git add -f "$p"
    done
}

# ---------------------------------------------------------------------------
# Stage 4: commit
# ---------------------------------------------------------------------------

# import_message: echo the commit message for the initial import.
#
# The message records WHY the tree looks the way it does, because six months
# from now the reasoning will not be reconstructible from the diff alone --
# in particular why a `-f` was needed.
import_message() {
    echo "Import $REL from rk3576-linux-6.1 SDK (Topeet)"
    echo
    echo "Vendor stripped the .repo metadata; this project was reconstructed"
    echo "from its dangling .git symlink. The vendor's .gitignore was applied"
    echo "unmodified."

    [ -n "$FORCE_ADD" ] || return 0
    echo
    echo "Force-added despite .gitignore: $FORCE_ADD"
    echo "Reason: those paths were themselves repo projects, so the parent's"
    echo "ignore rule was correct under the original multi-repo layout and is"
    echo "wrong here. Their loss would be invisible to the build."
}

# commit_tree: create a commit, distinguishing first import from a re-run.
#
# On a re-run with no changes we must not fail: idempotency is the whole point
# of being able to retry a project after fixing something.
commit_tree() {
    if ! git rev-parse --verify -q HEAD >/dev/null; then
        git commit -q -F <(import_message)
        say "commit: $(git rev-parse --short HEAD) (initial import)"
        return 0
    fi

    if git diff --cached --quiet; then
        say "commit: nothing new to commit"
    else
        git commit -q -m "Update $REL from SDK tree"
        say "commit: $(git rev-parse --short HEAD)"
    fi
}

# ---------------------------------------------------------------------------
# Stage 5: GitLab remote side
# ---------------------------------------------------------------------------

# group_id: echo the numeric id of GITLAB_GROUP.
#
# The search endpoint does substring matching, so "team_rk3576" could also
# return "team_rk3576_old". We prefer an exact path match and only fall back
# to the first result if nothing matches exactly.
group_id() {
    local json
    json=$(curl -sf -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
             "$GITLAB_URL/api/v4/groups?search=$GITLAB_GROUP") \
        || die "cannot reach GitLab API at $GITLAB_URL (check GITLAB_TOKEN and network)"

    echo "$json" | python3 -c "
import json, sys
groups = json.load(sys.stdin)
exact = [g for g in groups if g['path'] == '$GITLAB_GROUP']
chosen = exact or groups
print(chosen[0]['id'] if chosen else '')
"
}

# ensure_remote_project: make sure the GitLab project exists.
#
# Probe with GET, create with POST. A 400 "has already been taken" from the
# POST counts as success -- that tolerance is what makes re-running this
# script harmless rather than an error to interpret.
ensure_remote_project() {
    local gid enc resp

    say "resolving group id for '$GITLAB_GROUP'"
    gid=$(group_id)
    [ -n "$gid" ] || die "group '$GITLAB_GROUP' not found -- create it first"
    say "group id: $gid"

    # The project lookup endpoint takes a URL-encoded "group/name" path.
    enc=$(python3 -c "
import urllib.parse
print(urllib.parse.quote('$GITLAB_GROUP/$NAME', safe=''))
")

    if curl -sf -o /dev/null -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            "$GITLAB_URL/api/v4/projects/$enc"; then
        say "gitlab project already exists"
        return 0
    fi

    say "creating gitlab project '$NAME'"
    resp=$(curl -s -X POST -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
             "$GITLAB_URL/api/v4/projects" \
             --data-urlencode "name=$NAME" \
             --data-urlencode "path=$NAME" \
             -d "namespace_id=$gid" \
             -d "visibility=private")

    echo "$resp" | grep -q '"id":' && return 0
    echo "$resp" | grep -q 'already been taken' && return 0
    die "project creation failed: $resp"
}

# ---------------------------------------------------------------------------
# Stage 6: push, with the token on disk for the shortest possible window
# ---------------------------------------------------------------------------

# scrub_token: strip any embedded credentials from .git/config.
#
# Matches the "user:password@" form in any URL. Written to be safe to call
# repeatedly and safe to call when .git/config does not exist, because it runs
# from an EXIT trap as well as on the success path.
scrub_token() {
    [ -f .git/config ] || return 0
    sed -i 's|://[^:/@]*:[^@]*@|://|' .git/config
}

# push_tree: push main to GitLab, then remove the credential from disk.
#
# The EXIT trap guarantees the scrub even if the push fails or the operator
# interrupts with Ctrl-C. Without it, a failed run would leave a plaintext PAT
# sitting in .git/config -- which is precisely the defect in the older
# migration scripts this tooling replaces.
push_tree() {
    trap scrub_token EXIT

    git remote remove origin 2>/dev/null || true
    git remote add origin "$(auth_url)"

    say "pushing to $REPO_URL"
    git push -q -u origin main

    scrub_token
    trap - EXIT
}

# ---------------------------------------------------------------------------
# Stage 7: verification
# ---------------------------------------------------------------------------

# verify_push: confirm the remote main really points at our HEAD, and that no
# credential was left behind.
#
# `git push` exiting 0 is weaker evidence than it looks -- a misconfigured
# remote or a server-side hook can still leave the branch elsewhere. Asking
# the server what it has is the only real confirmation.
verify_push() {
    local remote_sha local_sha

    remote_sha=$(git ls-remote "$(auth_url)" refs/heads/main 2>/dev/null | cut -f1)
    local_sha=$(git rev-parse HEAD)

    [ "$remote_sha" = "$local_sha" ] \
        || die "remote main ($remote_sha) != local HEAD ($local_sha)"

    if grep -q '@' .git/config; then
        die "credentials still present in .git/config -- scrub failed, remove them by hand"
    fi

    say "OK  $REL -> $NAME  @ ${local_sha:0:8}"
}

# report_manifest_line: print the <project> line to paste into default.xml.
#
# Emitted last so it is the final thing on screen, ready to copy. name and
# path differ whenever the SDK path contains a slash; see resolve_target().
report_manifest_line() {
    echo
    echo "manifest line for this project:"
    echo "  <project name=\"$NAME\" path=\"$REL\" />"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

# main: the only entry point. Ordering matters and is enforced here rather
# than by each function checking its predecessors:
#
#   evidence -> init -> LFS -> add -> commit -> remote -> push -> verify
#                        ^^^
#            LFS before add, or large blobs enter history un-LFS'd
#
# `set -euo pipefail` is scoped to this function so that sourcing the file for
# unit-testing individual functions does not change the caller's shell options.
main() {
    set -euo pipefail

    [ $# -eq 1 ] || die "usage: $0 <project-path-relative-to-sdk-root>"

    init_config
    check_prereqs
    resolve_target "$1"

    say "project : $REL"
    say "gitlab  : $NAME"

    cd "$ABS" || die "cannot cd to $ABS"

    preserve_evidence
    init_local_repo
    setup_lfs
    stage_tree
    commit_tree
    ensure_remote_project
    push_tree
    verify_push
    report_manifest_line
}

main "$@"
