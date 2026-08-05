# shellcheck shell=bash
#
# gitlab.sh -- GitLab server side: API calls, and pushing the current
# repository to it.
#
# Knows about GitLab. Does not know that an SDK exists, and does not decide
# what to commit -- by the time anything here runs, the commit already exists.
#
# Every function takes the connection details as arguments rather than reading
# globals, so a caller can talk to two servers in one run without unsetting
# anything in between.
#
# Token handling is the one thing this file is strict about. The PAT is passed
# as an argument, enters .git/config only for the duration of the push, and is
# scrubbed immediately afterwards by an EXIT trap that fires even on Ctrl-C.
#
# Source-only. Not executable.

# gitlab_host: print the host portion of a GitLab base URL.
#
# $1 -- base URL, e.g. http://192.168.3.67
#
# Needed because embedding a credential requires splicing it between the
# scheme and the host: http://oauth2:TOKEN@host/group/name.git
gitlab_host() {
    local url="$1"
    url="${url#http://}"
    url="${url#https://}"
    echo "${url%%/*}"
}

# gitlab_repo_url: print the plain, credential-free clone URL.
#
# $1 -- base URL
# $2 -- group path
# $3 -- project name
#
# This is the form that is safe to print, log and paste. Use gitlab_auth_url
# only where a credential is genuinely required.
gitlab_repo_url() {
    echo "$1/$2/$3.git"
}

# gitlab_auth_url: print the push URL with the PAT spliced in.
#
# $1 -- base URL
# $2 -- group path
# $3 -- project name
# $4 -- PAT
#
# Kept as a function that prints to stdout, and never assigned to a variable
# that other functions can reach, so the token cannot leak through an
# accidental `say` of some shared global.
#
# The "oauth2" username is what GitLab expects for PAT-over-HTTP; the token
# goes in the password field.
gitlab_auth_url() {
    local host
    host=$(gitlab_host "$1")
    echo "http://oauth2:$4@$host/$2/$3.git"
}

# gitlab_group_id: print the numeric id of a group, or nothing if absent.
#
# $1 -- base URL
# $2 -- group path
# $3 -- PAT
#
# The search endpoint does substring matching, so searching "team_rk3576" can
# also return "team_rk3576_old". We take an exact path match when one exists
# and only fall back to the first result otherwise -- pushing into the wrong
# namespace is the kind of mistake that is tedious to undo.
gitlab_group_id() {
    local url="$1" group="$2" token="$3" json

    json=$(curl -sf -H "PRIVATE-TOKEN: $token" \
             "$url/api/v4/groups?search=$group") \
        || die "cannot reach GitLab API at $url (check the token and the network)"

    GITLAB_GROUP_PATH="$group" echo "$json" | python3 -c '
import json, os, sys

groups = json.load(sys.stdin)
wanted = os.environ["GITLAB_GROUP_PATH"]

# Prefer an exact match on either path or full_path, so a nested group given
# as "team/sub" resolves correctly too.
exact = [g for g in groups if wanted in (g.get("path"), g.get("full_path"))]
chosen = exact or groups
print(chosen[0]["id"] if chosen else "")
'
}

# gitlab_project_exists: return 0 if group/name already exists on the server.
#
# $1 -- base URL
# $2 -- group path
# $3 -- project name
# $4 -- PAT
#
# The project endpoint addresses a project by URL-encoded "group/name", so the
# '/' must be written as %2F or the request lands on a different route. Done by
# string substitution rather than a URL-encoding library because group and
# project paths are restricted by GitLab to characters that need no other
# escaping.
gitlab_project_exists() {
    local url="$1" group="$2" name="$3" token="$4"

    curl -sf -o /dev/null -H "PRIVATE-TOKEN: $token" \
        "$url/api/v4/projects/$group%2F$name"
}

# gitlab_ensure_project: make sure group/name exists, creating it if needed.
#
# $1 -- base URL
# $2 -- group path
# $3 -- project name
# $4 -- PAT
# $5 -- visibility: private, internal or public
#
# Probe with GET, create with POST. A 400 "has already been taken" from the
# POST counts as success: that tolerance is what makes re-running this harmless
# rather than an error the operator has to interpret. It also covers the race
# where two operators reclaim adjacent directories at the same moment.
gitlab_ensure_project() {
    local url="$1" group="$2" name="$3" token="$4" visibility="$5"
    local gid response

    if gitlab_project_exists "$url" "$group" "$name" "$token"; then
        say "gitlab: project '$group/$name' already exists"
        return 0
    fi

    say "gitlab: resolving group id for '$group'"
    gid=$(gitlab_group_id "$url" "$group" "$token")
    [ -n "$gid" ] || die "group '$group' not found on $url -- create it first"

    say "gitlab: creating project '$group/$name' (id $gid, $visibility)"
    response=$(curl -s -X POST -H "PRIVATE-TOKEN: $token" \
                 "$url/api/v4/projects" \
                 --data-urlencode "name=$name" \
                 --data-urlencode "path=$name" \
                 -d "namespace_id=$gid" \
                 -d "visibility=$visibility")

    case "$response" in
        *'"id":'*)               return 0 ;;
        *'already been taken'*)  say "gitlab: project appeared concurrently"; return 0 ;;
        *) die "project creation failed: $response" ;;
    esac
}

# gitlab_scrub_token: strip any embedded credential from .git/config.
#
# Matches the "user:password@" form in any URL. Written to be safe to call
# repeatedly and safe to call when .git/config does not exist, because it runs
# from an EXIT trap as well as on the normal path.
gitlab_scrub_token() {
    [ -f .git/config ] || return 0
    sed -i 's|://[^:/@]*:[^@]*@|://|' .git/config
}

# gitlab_push: push a branch of the current repository to GitLab.
#
# $1 -- base URL
# $2 -- group path
# $3 -- project name
# $4 -- PAT
# $5 -- branch name
#
# The EXIT trap guarantees the scrub even if the push fails or the operator
# interrupts with Ctrl-C. Without it, an aborted run leaves a plaintext PAT in
# .git/config -- precisely the defect in the older migration scripts this
# tooling replaces.
#
# The remote is removed and re-added rather than updated, so a re-run cannot
# inherit a stale URL from a previous attempt against a different server.
gitlab_push() {
    local url="$1" group="$2" name="$3" token="$4" branch="$5"

    trap gitlab_scrub_token EXIT

    git remote remove origin 2>/dev/null || true
    git remote add origin "$(gitlab_auth_url "$url" "$group" "$name" "$token")"

    say "pushing $branch to $(gitlab_repo_url "$url" "$group" "$name")"
    git push -q -u origin "$branch"

    gitlab_scrub_token
    trap - EXIT
}

# gitlab_verify_push: confirm the server's branch really points at our HEAD,
# and that no credential was left on disk.
#
# $1 -- base URL
# $2 -- group path
# $3 -- project name
# $4 -- PAT
# $5 -- branch name
# $6 -- the local sha the branch is expected to be at
#
# `git push` exiting 0 is weaker evidence than it looks: a misconfigured remote
# or a server-side hook can still leave the branch somewhere other than where
# we think. Asking the server what it actually has is the only real
# confirmation.
gitlab_verify_push() {
    local url="$1" group="$2" name="$3" token="$4" branch="$5" expected="$6"
    local remote_sha

    remote_sha=$(git ls-remote \
                   "$(gitlab_auth_url "$url" "$group" "$name" "$token")" \
                   "refs/heads/$branch" 2>/dev/null | cut -f1)

    [ -n "$remote_sha" ] \
        || die "remote has no $branch branch after push"

    [ "$remote_sha" = "$expected" ] \
        || die "remote $branch ($remote_sha) != local HEAD ($expected)"

    # Checked after the ls-remote, because that call itself embeds the token in
    # its argv; the invariant we care about is that nothing persists on disk.
    if grep -q '@' .git/config; then
        die "credentials still present in .git/config -- scrub failed, remove them by hand"
    fi

    say "verified: remote $branch == ${expected:0:8}"
}
