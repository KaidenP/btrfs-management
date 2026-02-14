# lib/logging.sh - Logging library for btrfs-management
# This file is meant to be sourced, never executed.

# Prevent direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "logging.sh is a library and must be sourced, not executed." >&2
    exit 1
fi

# Ensure strict mode compatibility (do NOT enable it here, only rely on it)
# Caller is expected to use: set -euo pipefail

# Idempotent initialization guard
if [[ -n "${__LOGGING_LIB_INITIALIZED:-}" ]]; then
    return 0
fi
__LOGGING_LIB_INITIALIZED=1

# -----------------------------
# Configuration Defaults
# -----------------------------
: "${LOG_RETENTION_DAYS:=90}"

if [[ -z "${LOG_FILE:-}" ]]; then
    echo "LOG_FILE must be set before sourcing logging.sh" >&2
    return 1
fi

__LOGGING_ENABLE_FILE=1
if [[ "${LOG_FILE}" == "null" ]]; then
    __LOGGING_ENABLE_FILE=0
fi

LOG_FILE="/var/log/btrfs-management/${LOG_FILE}"

# -----------------------------
# Internal State
# -----------------------------
__LOGGING_FD=""
__LOGGING_LOCK_FD=""
__LOGGING_COLOR=0
__LOGGING_SCRIPT_SOURCE="${BASH_SOURCE[1]:-unknown}"

# -----------------------------
# Color Detection
# -----------------------------
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    if [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
        __LOGGING_COLOR=1
    fi
fi

if [[ "${__LOGGING_COLOR}" -eq 1 ]]; then
    __LOG_COLOR_GREEN="$(tput setaf 2)"
    __LOG_COLOR_YELLOW="$(tput setaf 3)"
    __LOG_COLOR_RED="$(tput setaf 9 2>/dev/null || tput setaf 1)"
    __LOG_COLOR_RESET="$(tput sgr0)"
else
    __LOG_COLOR_GREEN=""
    __LOG_COLOR_YELLOW=""
    __LOG_COLOR_RED=""
    __LOG_COLOR_RESET=""
fi

# -----------------------------
# Utility
# -----------------------------
log_get_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

__log_prefix_plain() {
    local ts="$1"
    local level="$2"

    if [[ -n "${LOG_NAME:-}" ]]; then
        printf '[%s] [%s] [%s]: ' "$ts" "$LOG_NAME" "$level"
    else
        printf '[%s] [%s]: ' "$ts" "$level"
    fi
}

__log_prefix_color() {
    local ts="$1"
    local level="$2"

    local level_color=""
    case "$level" in
        INFO)  level_color="$__LOG_COLOR_GREEN" ;;
        WARN)  level_color="$__LOG_COLOR_YELLOW" ;;
        ERROR) level_color="$__LOG_COLOR_RED" ;;
    esac

    local bracket_green="${__LOG_COLOR_GREEN}"
    local reset="${__LOG_COLOR_RESET}"

    if [[ -n "${LOG_NAME:-}" ]]; then
        printf '%s[%s]%s %s[%s]%s %s[%s%s%s]:%s ' \
            "$bracket_green" "$ts" "$reset" \
            "$__LOG_COLOR_YELLOW" "$LOG_NAME" "$reset" \
            "$bracket_green" "$level_color" "$level" "$bracket_green" \
            "$reset"
    else
        printf '%s[%s]%s %s[%s%s%s]:%s ' \
            "$bracket_green" "$ts" "$reset" \
            "$bracket_green" "$level_color" "$level" "$bracket_green" \
            "$reset"
    fi
}

__log_write_file() {
    [[ "${__LOGGING_ENABLE_FILE}" -eq 1 ]] || return 0
    local text="$1"
    printf '%s\n' "$text" >&"${__LOGGING_FD}"
}

__log_multiline() {
    local level="$1"
    local output_fd="$2"
    shift 2

    local message="$*"
    local ts
    ts="$(log_get_timestamp)"

    local prefix_plain
    prefix_plain="$(__log_prefix_plain "$ts" "$level")"

    local prefix_color=""
    if [[ "${__LOGGING_COLOR}" -eq 1 ]]; then
        prefix_color="$(__log_prefix_color "$ts" "$level")"
    fi

    local IFS=$'\n'
    local line
    for line in ${message}; do
        if [[ "${__LOGGING_COLOR}" -eq 1 ]]; then
            printf '%s%s%s\n' "$prefix_color" "$line" "$__LOG_COLOR_RESET" >&"${output_fd}"
        else
            printf '%s%s\n' "$prefix_plain" "$line" >&"${output_fd}"
        fi
        __log_write_file "${prefix_plain}${line}"
    done
}

log_info() {
    __log_multiline "INFO" 1 "$@"
}

log_warn() {
    __log_multiline "WARN" 2 "$@"
}

log_err() {
    __log_multiline "ERROR" 2 "$@"
}


get_log() {
    # If file logging disabled, nothing to output
    [[ "${__LOGGING_ENABLE_FILE}" -eq 1 ]] || return 0

    # Ensure offset exists
    : "${__LOGGING_RUN_OFFSET:=0}"

    # Flush logfile FD before reading
    if [[ -n "${__LOGGING_FD:-}" ]]; then
        exec {__LOGGING_FD}>&-
    fi

    # Output only content from this run
    local current_size
    current_size=$(stat -c '%s' "$LOG_FILE" 2>/dev/null || stat -f '%z' "$LOG_FILE")

    if (( current_size > __LOGGING_RUN_OFFSET )); then
        # Use tail with byte offset for efficiency on large files
        tail -c +"$((__LOGGING_RUN_OFFSET + 1))" "$LOG_FILE"
    fi

    # Reopen logfile FD
    if [[ -n "${__LOGGING_FD:-}" ]]; then
        exec {__LOGGING_FD}>>"$LOG_FILE"
    fi
}

# -----------------------------
# File Initialization
# -----------------------------
if [[ "${__LOGGING_ENABLE_FILE}" -eq 1 ]]; then
    mkdir -p "$(dirname -- "$LOG_FILE")"

    # Open lock FD
    exec {__LOGGING_LOCK_FD}>"${LOG_FILE}.lock"
    flock -x "${__LOGGING_LOCK_FD}"

    # Retention Cleanup (atomic)
    if [[ -f "$LOG_FILE" ]]; then
        tmp_file="${LOG_FILE}.tmp.$$"
        cutoff_epoch=$(( $(date +%s) - LOG_RETENTION_DAYS*86400 ))

        awk -v cutoff="$cutoff_epoch" '
        function to_epoch(ts) {
            cmd="date -d \"" ts "\" +%s"
            cmd | getline out
            close(cmd)
            return out
        }
        /^# log started at / {
            ts=substr($0,18,19)
            if (to_epoch(ts) < cutoff) {
                skip=1
            } else {
                skip=0
            }
        }
        /^# log ended at / {
            if (skip==1) {
                skip=0
                next
            }
        }
        skip!=1 { print }
        ' "$LOG_FILE" > "$tmp_file"

        mv "$tmp_file" "$LOG_FILE"
    fi

    # Open logfile FD
    exec {__LOGGING_FD}>>"$LOG_FILE"

    # Record starting byte offset for this run
    __LOGGING_RUN_OFFSET=0
    if [[ -f "$LOG_FILE" ]]; then
        __LOGGING_RUN_OFFSET=$(stat -c '%s' "$LOG_FILE" 2>/dev/null || stat -f '%z' "$LOG_FILE")
    fi

    printf '# log started at %s by %s\n' \
        "$(log_get_timestamp)" \
        "$__LOGGING_SCRIPT_SOURCE" >&"${__LOGGING_FD}"

    __logging_exit_trap() {
        printf '# log ended at %s by %s\n' \
            "$(log_get_timestamp)" \
            "$__LOGGING_SCRIPT_SOURCE" >&"${__LOGGING_FD}"

        exec {__LOGGING_FD}>&-
        flock -u "${__LOGGING_LOCK_FD}"
        exec {__LOGGING_LOCK_FD}>&-
    }

    add_exit_trap __logging_exit_trap
fi
