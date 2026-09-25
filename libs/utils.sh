# shellcheck shell=bash
#
# utils.sh -- Generic output and precondition helpers.
#
# No domain knowledge lives here: nothing in this file knows about GitLab,
# SDKs or repo manifests. Anything that does belongs in another library.
#
# Every function is named libutils_*, following the libs/ convention that a
# function's prefix names the file it lives in. At a call site,
# libutils_require_cmd is traceable to libs/utils.sh without a search; a bare
# require_cmd is not, and in a script that also defines its own functions the
# distinction between "mine" and "the library's" is worth the extra characters.
#
# Source-only. Not executable.

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

# libutils_say: print a progress line on stderr.
#
# Prefixed with "==>" so our own narration stays visually separable from the
# git and curl output we deliberately do not suppress. When a run goes wrong
# halfway, the operator needs to see at a glance which line was ours.
#
# stderr, not stdout, for the same reason as libutils_warn: progress narration
# is for the operator watching, never part of a script's result. A script whose
# result goes to stdout can then be redirected with a plain '> file' while its
# narration still reaches the terminal -- and the operator does not have to
# strip "==>" lines back out of the file afterwards.
libutils_say() {
    echo "==> $*" >&2
}

# libutils_warn: print a non-fatal advisory on stderr.
#
# stderr rather than stdout, so a caller capturing our stdout (a future
# reclaim-all.sh collecting manifest lines) is not polluted by advisories.
libutils_warn() {
    echo "WARN: $*" >&2
}

# libutils_die: print a message on stderr and exit 1.
#
# Every failure path routes through here, so the exit status is always a clean
# 1 and never an ambiguous partial success a batch caller might misread.
libutils_die() {
    echo "ERROR: $*" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------

# libutils_require_cmd: die unless every named executable is on PATH.
#
# $@ -- command names
#
# Checked up front rather than at point of use. Failing before we touch
# anything costs nothing; failing after `git init` leaves a half-created
# repository the operator then has to reason about.
libutils_require_cmd() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null || libutils_die "required command not found: $cmd"
    done
}
