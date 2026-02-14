#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------
# snapshot
# Invoked via: btrfs-management snapshot
# ------------------------------------------------------------------
LOG_FILE="snapshot.log"

# Always executed from correct working directory
source ./src/lib.sh

require_root
ensure_packages

load_env_file /etc/btrfs-management/btrfs-management.config

# ------------------------------------------------------------------
# Globals
# ------------------------------------------------------------------

EMAIL_MODE=""
EMAIL_ON_FAILURE=0
EMAIL_ON_SUCCESS=0

TMP_FILE=""
BACKUP_TYPE=""
SNAPSHOT_NAME=""
TIMESTAMP=""
VOLUME_NAME=""
RETENTION_DAYS="${RETENTION_DAYS:-0}"

# ------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------

cleanup() {
    if [[ -n "${TMP_FILE:-}" && -f "${TMP_FILE:-}" ]]; then
        rm -f -- "$TMP_FILE" || true
    fi
}
trap cleanup EXIT

# ------------------------------------------------------------------
# Email Handling
# ------------------------------------------------------------------

send_email_if_needed() {
    local status="$1"
    local message="$2"

    if [[ "$status" -ne 0 && "$EMAIL_ON_FAILURE" -eq 1 ]]; then
        printf "%s\n" "$message" | send_mail "snapshot"
    elif [[ "$status" -eq 0 && "$EMAIL_ON_SUCCESS" -eq 1 ]]; then
        printf "%s\n" "$message" | send_mail "snapshot"
    fi
}

# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------

usage_synopsis() {
    echo "btrfs-management snapshot [-e|--email=<failure|always>] <create|delete|help> ..."
}

help_output() {
    cat <<EOF
Usage:
  btrfs-management snapshot [global options] <command> [args]

Global Options:
  -e                      Send email on failure
  --email=failure         Send email on failure
  --email=always          Send email on success and failure

Commands:

  create [-b] [--rw] <subvolume> [snapshot name]
      Create a snapshot.
      Default is read-only unless --rw specified.
      If -b specified, perform backup via btrfs send.
      Named snapshots stored in .snapshot/named/
      Timestamped snapshots stored in .snapshot/dated/

  delete <subvolume> <name|timestamp>
      Delete a snapshot from named or dated directories.

  help
      Show this help.

Email Behavior:
  failure   Email only on failure.
  always    Email on success and failure.

Backup Behavior:
  - Full backup if LAST_FULL_BACKUP undefined or older than FULL_BACKUP_INTERVAL_DAYS.
  - Otherwise incremental backup.
  - Metadata file updated with LAST_FULL_BACKUP.
  - Optional compression via COMPRESS_CMD.
  - Calls BACKUP_SCRIPT create and maintain.
EOF
}

validate_volume() {
    if [[ -z "${VOLUME_PATH:-}" ]]; then
        log_err "VOLUME_PATH not defined in volume config"
        exit 1
    fi
}

load_volume() {
    VOLUME_NAME="$1"
    load_env_file "/etc/btrfs-management/volumes.d/${VOLUME_NAME}.config"
    validate_volume
    load_env_file "${VOLUME_PATH}/metadata" || true
}

generate_timestamp() {
    date +"%Y-%m-%d-%H%M"
}

create_snapshot() {
    local backup=0
    local rw=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -b) backup=1 ;;
            --rw) rw=1 ;;
            *) break ;;
        esac
        shift
    done

    if [[ $# -lt 1 ]]; then
        log_err "Missing subvolume name"
        exit 1
    fi

    local subvolume="$1"
    shift

    local provided_name="${1:-}"

    load_volume "$subvolume"

    local source="${VOLUME_PATH}/current"
    local snapshot_dir
    local snapshot_path

    if [[ -n "$provided_name" ]]; then
        SNAPSHOT_NAME="$provided_name"
        snapshot_dir="${VOLUME_PATH}/.snapshot/named"
        snapshot_path="${snapshot_dir}/${SNAPSHOT_NAME}"
    else
        TIMESTAMP="$(generate_timestamp)"
        SNAPSHOT_NAME="$TIMESTAMP"
        snapshot_dir="${VOLUME_PATH}/.snapshot/dated"
        snapshot_path="${snapshot_dir}/${TIMESTAMP}"
    fi

    mkdir -p -- "$snapshot_dir"

    if [[ -d "$snapshot_path" ]]; then
        log_info "Snapshot already exists: $snapshot_path"
    else
        log_info "Creating snapshot: $snapshot_path"
        if [[ "$rw" -eq 1 ]]; then
            btrfs subvolume snapshot "$source" "$snapshot_path"
        else
            btrfs subvolume snapshot -r "$source" "$snapshot_path"
        fi
    fi

    if [[ "$backup" -eq 1 ]]; then
        perform_backup "$subvolume" "$snapshot_path"
    fi

    if [[ -z "$provided_name" && "$RETENTION_DAYS" -gt 0 ]]; then
        apply_retention
        if [[ -n "${BACKUP_SCRIPT:-}" && -x "${BACKUP_SCRIPT:-}" ]]; then
            "$BACKUP_SCRIPT" maintain
        fi
    fi
}

perform_backup() {
    local subvolume="$1"
    local snapshot_path="$2"

    if [[ -z "${BACKUP_SCRIPT:-}" || ! -x "${BACKUP_SCRIPT:-}" ]]; then
        log_err "BACKUP_SCRIPT not defined or not executable"
        exit 1
    fi

    TMP_FILE="$(mktemp)"

    local now_epoch
    now_epoch="$(date +%s)"

    local full_interval_days="${FULL_BACKUP_INTERVAL_DAYS:-0}"
    local last_full_epoch=0

    if [[ -n "${LAST_FULL_BACKUP:-}" ]]; then
        last_full_epoch="$(date -d "${LAST_FULL_BACKUP}" +%s 2>/dev/null || echo 0)"
    fi

    local perform_full=1

    if [[ -n "${LAST_FULL_BACKUP:-}" && "$full_interval_days" -gt 0 ]]; then
        local age_days=$(( (now_epoch - last_full_epoch) / 86400 ))
        if [[ "$age_days" -lt "$full_interval_days" ]]; then
            perform_full=0
        fi
    fi

    if [[ "$perform_full" -eq 1 ]]; then
        BACKUP_TYPE="full"
        LAST_FULL_BACKUP="$(date +"%Y-%m-%d-%H%M")"
        echo "LAST_FULL_BACKUP=${LAST_FULL_BACKUP}" > "${VOLUME_PATH}/metadata"
        btrfs send "$snapshot_path" | ${COMPRESS_CMD:-cat} > "$TMP_FILE"
    else
        BACKUP_TYPE="incremental"
        local parent_snapshot
        parent_snapshot="$(find "${VOLUME_PATH}/.snapshot/dated" -maxdepth 1 -type d | sort | tail -n 1)"
        btrfs send -p "$parent_snapshot" "$snapshot_path" | ${COMPRESS_CMD:-cat} > "$TMP_FILE"
    fi

    local ext="${EXTENTION:-}"
    local filename="${SNAPSHOT_NAME}.${BACKUP_TYPE}.btrfs${ext:+.$ext}"

    "$BACKUP_SCRIPT" create "$subvolume" "$TMP_FILE" "$filename"
}

apply_retention() {
    log_info "Applying retention: ${RETENTION_DAYS} days"
    find "${VOLUME_PATH}/.snapshot/dated" -mindepth 1 -maxdepth 1 -type d -mtime +"$RETENTION_DAYS" -exec btrfs subvolume delete {} \;
}

delete_snapshot() {
    if [[ $# -ne 2 ]]; then
        log_err "delete requires <subvolume> <name|timestamp>"
        exit 1
    fi

    local subvolume="$1"
    local name="$2"

    load_volume "$subvolume"

    local path_named="${VOLUME_PATH}/.snapshot/named/${name}"
    local path_dated="${VOLUME_PATH}/.snapshot/dated/${name}"

    local target=""

    if [[ -d "$path_named" ]]; then
        target="$path_named"
    elif [[ -d "$path_dated" ]]; then
        target="$path_dated"
    else
        log_err "Snapshot not found: $name"
        exit 1
    fi

    log_info "Deleting snapshot: $target"
    btrfs subvolume delete "$target"
}

# ------------------------------------------------------------------
# Argument Parsing
# ------------------------------------------------------------------

parse_global_options() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -e)
                EMAIL_MODE="failure"
                shift
                ;;
            --email=*)
                EMAIL_MODE="${1#*=}"
                shift
                ;;
            --)
                shift
                break
                ;;
            *)
                break
                ;;
        esac
    done

    case "${EMAIL_MODE:-}" in
        failure|"")
            EMAIL_ON_FAILURE=1
            ;;
        always)
            EMAIL_ON_FAILURE=1
            EMAIL_ON_SUCCESS=1
            ;;
        *)
            log_err "Invalid email mode: $EMAIL_MODE"
            exit 1
            ;;
    esac

    COMMAND="${1:-}"
    shift || true
    COMMAND_ARGS=("$@")
}

# ------------------------------------------------------------------
# Main
# ------------------------------------------------------------------

main() {
    parse_global_options "$@"

    local status=0
    local output_msg=""

    case "$COMMAND" in
        create)
            create_snapshot "${COMMAND_ARGS[@]}" || status=$?
            ;;
        delete)
            delete_snapshot "${COMMAND_ARGS[@]}" || status=$?
            ;;
        help)
            help_output
            exit 0
            ;;
        synopsis)
            usage_synopsis
            exit 0
            ;;
        *)
            usage_synopsis
            exit 1
            ;;
    esac

    if [[ "$status" -eq 0 ]]; then
        output_msg="Snapshot command succeeded"
    else
        output_msg="Snapshot command failed"
    fi

    send_email_if_needed "$status" "$output_msg"
    return "$status"
}

main "$@"
