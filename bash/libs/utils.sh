# shellcheck shell=bash
#
# utils.sh -- Generic output and precondition helpers.
#
# No domain knowledge lives here: nothing in this file knows about GitLab,
# SDKs or repo manifests. Anything that does belongs in another library.
#
# Source-only. Not executable.

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

# say: print a progress line on stdout.
#
# Prefixed with "==>" so our own narration stays visually separable from the
# git and curl output we deliberately do not suppress. When a run goes wrong
# halfway, the operator needs to see at a glance which line was ours.
say() {
    echo "==> $*"
}

# warn: print a non-fatal advisory on stderr.
#
# stderr rather than stdout, so a caller capturing our stdout (a future
# reclaim-all.sh collecting manifest lines) is not polluted by advisories.
warn() {
    echo "WARN: $*" >&2
}

# die: print a message on stderr and exit 1.
#
# Every failure path routes through here, so the exit status is always a clean
# 1 and never an ambiguous partial success a batch caller might misread.
die() {
    echo "ERROR: $*" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------

# require_cmd: die unless every named executable is on PATH.
#
# $@ -- command names
#
# Checked up front rather than at point of use. Failing before we touch
# anything costs nothing; failing after `git init` leaves a half-created
# repository the operator then has to reason about.
require_cmd() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null || die "required command not found: $cmd"
    done
}
