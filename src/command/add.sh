#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# add
# -----------------------------------------------------------------------------
# Script to create or snapshot a managed Btrfs subvolume
# -----------------------------------------------------------------------------

LOG_FILE="add.log"

# Source library functions
source ./src/lib.sh

# Ensure script is run as root
require_root

# Helper function: print synopsis
synopsis() {
    echo "Create a managed Btrfs subvolume"
}

# Helper function: print detailed help
help_msg() {
    cat <<EOF
Usage:
  btrfs-management add <target> [source]

Description:
  Creates a managed Btrfs subvolume at <target>/current. If <source> is provided and is a
  Btrfs subvolume (or contains one at <source>/current), a read-write snapshot is
  created into <target>/current.
  
Examples:
  $0 /mnt/data/myvol
  $0 /mnt/data/myvol /mnt/data/basevol
EOF
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
    help_msg
    log_err "Missing target argument"
    exit 1
fi

TARGET="${1%%/}"
SOURCE="${2:-}"

# Handle special commands
case "$TARGET" in
    synopsis)
        synopsis
        exit 0
        ;;
    help)
        help_msg
        exit 0
        ;;
esac

# Remove /current suffix if present
if [[ "$TARGET" == */current ]]; then
    TARGET="${TARGET%/current}"
fi

CURRENT="$TARGET/current"

log_info "Target path: $TARGET"
log_info "Current subvolume path: $CURRENT"

# -----------------------------------------------------------------------------
# Handle existing target
# -----------------------------------------------------------------------------
if [[ -e "$TARGET" ]]; then
    if btrfs subvolume show "$TARGET" &>/dev/null; then
        # Move existing subvolume to $TARGET/current
        if [[ ! -e "$CURRENT" ]]; then
            log_info "Moving existing subvolume $TARGET -> $CURRENT"
            mv "$TARGET" "$TARGET.old"
            mkdir -p "$TARGET"
            mv "$TARGET.old" "$CURRENT"
        else
            log_info "$CURRENT already exists, skipping move"
        fi
    elif [[ -d "$CURRENT" ]] && btrfs subvolume show "$CURRENT" &>/dev/null; then
        log_info "$CURRENT already exists, proceeding"
    else
        log_err "$TARGET exists but is not a valid Btrfs subvolume or does not contain /current"
        exit 1
    fi
fi

# -----------------------------------------------------------------------------
# Snapshot from source if provided
# -----------------------------------------------------------------------------
if [[ -n "$SOURCE" ]]; then
    SNAP_SRC="$SOURCE"
    if [[ "$SOURCE" == */current ]]; then
        SNAP_SRC="${SOURCE%/current}"
    fi

    if btrfs subvolume show "$SOURCE" &>/dev/null; then
        SNAP_SRC="$SOURCE"
    elif [[ -d "$SOURCE/current" ]] && btrfs subvolume show "$SOURCE/current" &>/dev/null; then
        SNAP_SRC="$SOURCE/current"
    else
        log_err "Source $SOURCE is not a valid Btrfs subvolume or does not contain /current"
        exit 1
    fi

    # Create snapshot if it does not already exist
    if [[ ! -e "$CURRENT" ]]; then
        log_info "Creating read-write snapshot from $SNAP_SRC -> $CURRENT"
        btrfs subvolume snapshot -r "$SNAP_SRC" "$CURRENT"
    else
        log_info "$CURRENT already exists, skipping snapshot"
    fi
fi

# -----------------------------------------------------------------------------
# Create new subvolume if none exists
# -----------------------------------------------------------------------------
if [[ ! -e "$CURRENT" ]]; then
    log_info "Creating new subvolume at $CURRENT"
    mkdir -p "$TARGET"
    btrfs subvolume create "$CURRENT"
fi

# -----------------------------------------------------------------------------
# Copy volume config
# -----------------------------------------------------------------------------
VOLUME_DIR="/etc/btrfs-management/volumes.d"
VOLUME_FILE="$VOLUME_DIR/$(basename "$TARGET").config"

if [[ ! -e "$VOLUME_FILE" ]]; then
    log_info "Creating volume config $VOLUME_FILE"
    cp "$VOLUME_DIR/volume.config.example" "$VOLUME_FILE"
    # Replace VOLUME_PATH line
    sed -i "s|^VOLUME_PATH=.*|VOLUME_PATH=$TARGET|" "$VOLUME_FILE"
else
    log_err "Volume config $VOLUME_FILE already exists"
    exit 1
fi

# -----------------------------------------------------------------------------
# Create snapshot directories
# -----------------------------------------------------------------------------
for subdir in ".snapshots/named" ".snapshots/dated"; do
    dir="$TARGET/$subdir"
    if [[ ! -d "$dir" ]]; then
        log_info "Creating directory $dir"
        mkdir -p "$dir"
    else
        log_info "Directory $dir already exists, skipping"
    fi
done

log_info "Subvolume creation/setup complete."
