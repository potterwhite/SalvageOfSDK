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
# Elapsed-time clock
# ---------------------------------------------------------------------------

# libutils_clock_start: begin measuring wall-clock time for this run.
#
# Call once near the top of main, AFTER --help handling (a help print must not
# report "ran for 0 seconds"), and arrange for libutils_clock_report to run
# from the script's EXIT trap. The operator keeps forgetting to type `time`,
# and these runs are long -- a full push is hours -- so the measurement lives
# in the scripts themselves.
libutils_clock_start() {
    LIBUTILS_CLOCK_T0=$SECONDS
}

# libutils_clock_report: print elapsed time since libutils_clock_start.
#
# stderr, like libutils_say. A no-op when the clock was never started, so a
# trap firing before the start line cannot print nonsense. The variable is
# unset afterwards: an EXIT trap plus an explicit call at the end of main
# would otherwise print the line twice.
#
# Note for trap composition: this function is safe to call from another trap
# handler (e.g. a cleanup trap), which is how scripts that already own the
# EXIT trap add the clock without clobbering their cleanup.
libutils_clock_report() {
    [ -n "${LIBUTILS_CLOCK_T0:-}" ] || return 0

    local s=$((SECONDS - LIBUTILS_CLOCK_T0))
    unset LIBUTILS_CLOCK_T0

    if [ "$s" -ge 3600 ]; then
        printf '==> 总耗时 %d小时%d分%d秒\n' $((s / 3600)) $((s % 3600 / 60)) $((s % 60)) >&2
    else
        printf '==> 总耗时 %d分%d秒\n' $((s / 60)) $((s % 60)) >&2
    fi
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
