# shellcheck shell=bash
#
# args.sh -- Long-option command line parsing.
#
# No domain knowledge: this file does not know which options exist. The caller
# declares them. That is what lets the same parser serve reclaim-one.sh,
# reclaim-all.sh, and anything added later.
#
# No global state either. Every function takes the full argument list and
# scans it. Rescanning a six-element list is free, and in exchange there is
# nothing to initialise, nothing to reset, and no order dependency between
# calls -- which is what "low coupling" means in practice here.
#
# Accepted forms:
#   --key=value    preferred; unambiguous even when the value starts with '-'
#   --key value    accepted; the value must not itself begin with '--'
#   --flag         boolean; args_is_true reports it as true
#
# Underscores and hyphens are equivalent: --gitlab_url and --gitlab-url name
# the same option, because operators type both and making them differ would be
# a trap with no upside.
#
# Source-only. Not executable.

# args_key: print the canonical form of an option name.
#
# $1 -- raw name, with or without leading dashes
#
# Strips leading dashes and folds '_' to '-' so every other function in this
# file can compare names by plain string equality.
args_key() {
    local key="$1"
    key="${key#--}"
    echo "${key//_/-}"
}

# args_get: print an option's value, or a default when it was not supplied.
#
# $1  -- option name (any accepted spelling)
# $2  -- default value; pass "" for none
# $3+ -- the caller's full argument list
#
# Later occurrences win, so a wrapper script can append an override to an
# existing argument list without having to remove the earlier value.
args_get() {
    local want value arg
    want=$(args_key "$1")
    value="$2"
    shift 2

    while [ $# -gt 0 ]; do
        arg="$1"
        case "$arg" in
            --*=*)
                # Split on the FIRST '=' only, so a value may itself contain
                # '=' -- a URL query string, for instance.
                if [ "$(args_key "${arg%%=*}")" = "$want" ]; then
                    value="${arg#*=}"
                fi
                ;;
            --*)
                if [ "$(args_key "$arg")" = "$want" ]; then
                    # Consume the next token as this option's value only if it
                    # exists and does not look like another option. Otherwise
                    # this is a bare flag. Consequence: a value that genuinely
                    # begins with '--' must use the --key=value form.
                    if [ $# -ge 2 ] && [ "${2#--}" = "$2" ]; then
                        value="$2"
                    else
                        value="true"
                    fi
                fi
                ;;
        esac
        shift
    done

    echo "$value"
}

# args_has: return 0 if the option appears in the argument list at all.
#
# $1  -- option name
# $2+ -- the caller's full argument list
#
# Distinguishes "operator wrote --visibility=" from "operator never mentioned
# --visibility", a difference args_get deliberately flattens.
args_has() {
    local want arg
    want=$(args_key "$1")
    shift

    for arg in "$@"; do
        case "$arg" in
            --*=*) [ "$(args_key "${arg%%=*}")" = "$want" ] && return 0 ;;
            --*)   [ "$(args_key "$arg")" = "$want" ] && return 0 ;;
        esac
    done
    return 1
}

# args_is_true: return 0 if the option is present and not a negative literal.
#
# $1  -- option name
# $2+ -- the caller's full argument list
#
# A bare --dry-run parses to "true", but a wrapper script may well write
# --dry-run=false. Accepting the negative spellings costs one case statement
# and closes a silent-misconfiguration hole where "false" would be truthy
# merely by being a non-empty string.
args_is_true() {
    local name="$1" value
    shift
    args_has "$name" "$@" || return 1

    value=$(args_get "$name" "" "$@")
    case "$value" in
        ''|0|false|False|FALSE|no|No|NO) return 1 ;;
        *) return 0 ;;
    esac
}

# args_positional: print the Nth non-option argument, counting from 0.
#
# $1  -- index
# $2  -- default when that index does not exist
# $3  -- space-separated names of the caller's boolean flags
# $4+ -- the caller's full argument list
#
# The boolean list is required, and it is the reason this function is not a
# one-liner. Given `--dry-run docs`, a parser that does not know --dry-run is
# boolean consumes "docs" as its value, the positional silently becomes the
# default, and the script operates on the wrong directory while reporting
# success. Declaring the flags converts that into correct behaviour rather than
# a warning nobody reads.
#
# Pass "" when the caller has no boolean flags.
args_positional() {
    local want="$1" default="$2" flags=" " seen=0 name arg
    shift 2

    for name in $1; do
        flags+="$(args_key "$name") "
    done
    shift

    while [ $# -gt 0 ]; do
        arg="$1"
        case "$arg" in
            --*=*) ;;
            --*)
                name=$(args_key "$arg")
                case "$flags" in
                    *" $name "*)
                        # A declared boolean takes no value; leave the next
                        # token for consideration as a positional.
                        ;;
                    *)
                        # A value-taking option consumes the next token, unless
                        # that token is itself an option.
                        if [ $# -ge 2 ] && [ "${2#--}" = "$2" ]; then
                            shift
                        fi
                        ;;
                esac
                ;;
            *)
                if [ "$seen" -eq "$want" ]; then
                    echo "$arg"
                    return 0
                fi
                seen=$((seen + 1))
                ;;
        esac
        shift
    done

    echo "$default"
}

# args_check_known: die if an option was supplied that the caller never
# declared.
#
# $1  -- space-separated list of every option name the caller understands
# $2+ -- the caller's full argument list
#
# This is the main reason a parser module earns its place. Without it a typo
# like --gitlab_ur=http://... is silently ignored and the run proceeds against
# the default server, producing a wrong result that looks like a right one.
# Rejecting unknown names converts that into an error message.
args_check_known() {
    local declared=" " known="$1" name arg key
    shift

    for name in $known; do
        declared+="$(args_key "$name") "
    done

    for arg in "$@"; do
        case "$arg" in
            --*=*) key=$(args_key "${arg%%=*}") ;;
            --*)   key=$(args_key "$arg") ;;
            *)     continue ;;
        esac

        case "$declared" in
            *" $key "*) ;;
            *) die "unknown option: --$key" ;;
        esac
    done
}
