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

# libgitlab_host: print the host portion of a GitLab base URL.
#
# $1 -- base URL, e.g. http://gitlab.example.com
#
# Needed because embedding a credential requires splicing it between the
# scheme and the host: http://oauth2:TOKEN@host/group/name.git
libgitlab_host() {
    local url="$1"
    url="${url#http://}"
    url="${url#https://}"
    echo "${url%%/*}"
}

# libgitlab_repo_url: print the plain, credential-free HTTP clone URL.
#
# $1 -- base URL
# $2 -- group path
# $3 -- project name
#
# This is the form that is safe to print, log and paste. Use libgitlab_auth_url
# only where a credential is genuinely required.
#
# Prefer libgitlab_ssh_url for anything a human will run: plain HTTP has no
# credential attached, so a clone from it just fails with "Access denied".
libgitlab_repo_url() {
    echo "$1/$2/$3.git"
}

# libgitlab_ssh_base: print the SSH base URL for a group, with trailing slash.
#
# $1 -- base URL (only its hostname is used)
# $2 -- group path
#
# This is what a repo manifest's fetch= attribute needs: repo concatenates it
# with each project name, so it must end in a slash and must be a real URL --
# the scp-like git@host:path form does not survive concatenation.
#
# The port from libgitlab_host is dropped: it belongs to the web listener, while
# SSH answers on 22. Keeping it would silently point every clone at the wrong
# port on any GitLab not served from :80.
libgitlab_ssh_base() {
    local host
    host=$(libgitlab_host "$1")
    echo "ssh://git@${host%%:*}/$2/"
}

# libgitlab_ssh_url: print the SSH clone URL for one project.
#
# $1 -- base URL (only its hostname is used)
# $2 -- group path
# $3 -- project name
#
# This is the form to hand to people. SSH keys are already per-user and
# non-expiring, whereas HTTP would need every colleague to store a PAT in
# plaintext; and `repo sync` runs many fetches in parallel with interactive
# prompting disabled, so a password it cannot ask for is fatal.
libgitlab_ssh_url() {
    echo "$(libgitlab_ssh_base "$1" "$2")$3.git"
}

# libgitlab_auth_url: print the push URL with the PAT spliced in.
#
# $1 -- base URL
# $2 -- group path
# $3 -- project name
# $4 -- PAT
#
# Kept as a function that prints to stdout, and never assigned to a variable
# that other functions can reach, so the token cannot leak through an
# accidental `libutils_say` of some shared global.
#
# The "oauth2" username is what GitLab expects for PAT-over-HTTP; the token
# goes in the password field.
libgitlab_auth_url() {
    local host
    host=$(libgitlab_host "$1")
    echo "http://oauth2:$4@$host/$2/$3.git"
}

# libgitlab_group_id: print the numeric id of a group, or nothing if absent.
#
# $1 -- base URL
# $2 -- group path
# $3 -- PAT
#
# The search endpoint does substring matching, so searching "team_rk3576" can
# also return "team_rk3576_old". We take an exact path match when one exists
# and only fall back to the first result otherwise -- pushing into the wrong
# namespace is the kind of mistake that is tedious to undo.
libgitlab_group_id() {
    local url="$1" group="$2" token="$3" json

    json=$(curl -sf -H "PRIVATE-TOKEN: $token" \
             "$url/api/v4/groups?search=$group") \
        || libutils_die "cannot reach GitLab API at $url (check the token and the network)"

    # The group name is passed as an argument, not as an environment variable.
    # A "VAR=x cmd | other" prefix applies only to the left-hand command, so
    # the variable would never reach python3 at all.
    echo "$json" | python3 -c '
import json, sys

groups = json.load(sys.stdin)
wanted = sys.argv[1]

# Prefer an exact match on either path or full_path, so a nested group given
# as "team/sub" resolves correctly too.
exact = [g for g in groups if wanted in (g.get("path"), g.get("full_path"))]
chosen = exact or groups
print(chosen[0]["id"] if chosen else "")
' "$group"
}

# libgitlab_project_exists: return 0 if group/name already exists on the server.
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
libgitlab_project_exists() {
    local url="$1" group="$2" name="$3" token="$4"

    curl -sf -o /dev/null -H "PRIVATE-TOKEN: $token" \
        "$url/api/v4/projects/$group%2F$name"
}

# libgitlab_ensure_project: make sure group/name exists, creating it if needed.
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
libgitlab_ensure_project() {
    local url="$1" group="$2" name="$3" token="$4" visibility="$5"
    local gid response

    if libgitlab_project_exists "$url" "$group" "$name" "$token"; then
        libutils_say "gitlab: project '$group/$name' already exists"
        return 0
    fi

    libutils_say "gitlab: resolving group id for '$group'"
    gid=$(libgitlab_group_id "$url" "$group" "$token")
    [ -n "$gid" ] || libutils_die "group '$group' not found on $url -- create it first"

    libutils_say "gitlab: creating project '$group/$name' (id $gid, $visibility)"
    response=$(curl -s -X POST -H "PRIVATE-TOKEN: $token" \
                 "$url/api/v4/projects" \
                 --data-urlencode "name=$name" \
                 --data-urlencode "path=$name" \
                 -d "namespace_id=$gid" \
                 -d "visibility=$visibility")

    case "$response" in
        *'"id":'*)               return 0 ;;
        *'already been taken'*)  libutils_say "gitlab: project appeared concurrently"; return 0 ;;
        *) libutils_die "project creation failed: $response" ;;
    esac
}

# libgitlab_scrub_token: strip any embedded credential from .git/config.
#
# Matches the "user:password@" form in any URL. Written to be safe to call
# repeatedly and safe to call when .git/config does not exist, because it runs
# from an EXIT trap as well as on the normal path.
libgitlab_scrub_token() {
    [ -f .git/config ] || return 0
    sed -i 's|://[^:/@]*:[^@]*@|://|' .git/config
}

# libgitlab_setup_remote: point a remote at the credential-free SSH URL.
#
# $1 -- base URL
# $2 -- group path
# $3 -- project name
# $4 -- remote name. default origin, for an empty value too
#
# The SSH form, so the remote a person inherits is one they can actually use:
# `git push <remote> main` goes through their own key, with nothing to type and
# nothing stored. This is the same base the manifest fetches from, so a
# directory adopted here and a directory synced by repo end up agreeing.
#
# Removed and re-added rather than set-url, so a re-run cannot inherit a stale
# URL from an earlier attempt against a different server.
#
# Idempotent, and called by libgitlab_push's own exit path as well as by
# callers. A caller that only needs the default `origin` need not call it at all
# after a push; one that wants a differently-named remote still does.
libgitlab_setup_remote() {
    local url="$1" group="$2" name="$3" remote="${4:-origin}"
    git remote remove "$remote" 2>/dev/null || true
    git remote add "$remote" "$(libgitlab_ssh_url "$url" "$group" "$name")"
}

# libgitlab_push: push a branch of the current repository to GitLab.
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
# The trap also restores the SSH remote, because scrubbing alone leaves origin
# at a bare HTTP URL: credential-free, but unusable -- it prompts for a password
# nobody has. A caller running under `set -e` dies on a failed push before it
# can set the remote itself, so that half-state is exactly what an operator
# finds after a failure. Repairing it here means every exit path, successful or
# not, ends with a remote that works.
#
# The remote is removed and re-added rather than updated, so a re-run cannot
# inherit a stale URL from a previous attempt against a different server.
libgitlab_push() {
    local url="$1" group="$2" name="$3" token="$4" branch="$5"

    # Expanded now, not at trap time: a trap body runs after the function's
    # locals are gone.
    trap "libgitlab_scrub_token
          libgitlab_setup_remote '$url' '$group' '$name'" EXIT

    git remote remove origin 2>/dev/null || true
    git remote add origin "$(libgitlab_auth_url "$url" "$group" "$name" "$token")"

    libutils_say "pushing $branch to $(libgitlab_repo_url "$url" "$group" "$name")"
    git push -q -u origin "$branch"

    # Done here as well as in the trap, so the state a caller's verify step
    # inspects is the final one rather than whatever the trap will make of it.
    libgitlab_scrub_token
    libgitlab_setup_remote "$url" "$group" "$name"
    trap - EXIT
}

# libgitlab_verify_push: confirm the server's branch really points at our HEAD,
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
libgitlab_verify_push() {
    local url="$1" group="$2" name="$3" token="$4" branch="$5" expected="$6"
    local remote_sha

    remote_sha=$(git ls-remote \
                   "$(libgitlab_auth_url "$url" "$group" "$name" "$token")" \
                   "refs/heads/$branch" 2>/dev/null | cut -f1)

    [ -n "$remote_sha" ] \
        || libutils_die "remote has no $branch branch after push"

    [ "$remote_sha" = "$expected" ] \
        || libutils_die "remote $branch ($remote_sha) != local HEAD ($expected)"

    # Checked after the ls-remote, because that call itself embeds the token in
    # its argv; the invariant we care about is that nothing persists on disk.
    #
    # The pattern is "://user:pass@", not a bare '@'. A bare '@' also matches a
    # perfectly innocent `email = someone@example.com` from `git config --local
    # user.email`, which would abort a successful push and send the operator
    # hunting for a credential that was never there.
    if grep -q '://[^:/@]*:[^@]*@' .git/config; then
        libutils_die "credentials still present in .git/config -- scrub failed, remove them by hand"
    fi

    libutils_say "verified: remote $branch == ${expected:0:8}"
}
