#!/usr/bin/env bash
set -euo pipefail
# set -x

############################################
# BTRFS Management Installer
############################################

readonly SCRIPT_NAME="$(basename "$0")"

log() {
    echo "[INFO] $*"
}

warn() {
    echo "[WARN] $*" >&2
}

error() {
    echo "[ERROR] $*" >&2
    exit 1
}

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        error "This installer must be run as root."
    fi
}

resolve_script_dir() {
    local src
    src="${BASH_SOURCE[0]}"
    while [[ -h "$src" ]]; do
        local dir
        dir="$(cd -P "$(dirname "$src")" && pwd)"
        src="$(readlink "$src")"
        [[ "$src" != /* ]] && src="$dir/$src"
    done
    cd -P "$(dirname "$src")" && pwd
}

safe_copy_project() {
    local source_dir="$1"
    local dest_dir="$2"

    # Resolve absolute paths for comparison
    local src_abs
    local dst_abs
    src_abs=$(realpath "$source_dir")
    dst_abs=$(realpath "$dest_dir")

    if [ "$src_abs" = "$dst_abs" ]; then
        log "Source and destination are the same ($src_abs), skipping copy"
        return 0
    fi

    rm -rf "$dest_dir"
    mkdir -p "$dest_dir"

    log "Synchronizing project files from $source_dir to $dest_dir"
    {
        git -C "$source_dir" ls-files -z --cached --others --exclude-standard
        echo -n ".git/"
    } | \
        rsync -a --delete --files-from=- --from0 "$source_dir/" "$dest_dir/"
}

ensure_symlink() {
    local target="$1"
    local link_path="$2"

    if [[ ! -f "$target" ]]; then
        error "Expected executable not found: $target"
    fi

    if [[ -L "$link_path" ]]; then
        local current
        current="$(readlink -f "$link_path")"
        if [[ "$current" == "$target" ]]; then
            log "Symlink already correct: $link_path"
            return
        else
            log "Updating existing symlink: $link_path"
            rm -f "$link_path"
        fi
    elif [[ -e "$link_path" ]]; then
        error "$link_path exists and is not a symlink. Refusing to overwrite."
    fi

    ln -s "$target" "$link_path"
    log "Created symlink: $link_path -> $target"
}

ensure_config() {
    local install_dir="$1"
    local etc_dir="/etc/btrfs-management"
    local config_example="$install_dir/conf/btrfs-management.config.example"
    local config_file="$etc_dir/btrfs-management.config"

    mkdir -p "$etc_dir"

    if [[ ! -f "$config_example" ]]; then
        error "Missing example config: $config_example"
    fi

    if [[ ! -f "$config_file" ]]; then
        cp "$config_example" "$config_file"
        log "Created config: $config_file"
    else
        warn "Config already exists and was not modified: $config_file"
        warn "The example config may contain new options. Please review:"
        warn "  $config_example"
    fi

    mkdir -p "$etc_dir/volumes.d"

    local volume_example="$install_dir/conf/volume.config.example"
    local volume_target="$etc_dir/volumes.d/volume.config.example"

    if [[ ! -f "$volume_example" ]]; then
        error "Missing example volume config: $volume_example"
    fi

    cp "$volume_example" "$volume_target"
    log "Installed example volume config (overwritten if existed): $volume_target"
}

ensure_log_dir() {
    local log_dir="/var/log/btrfs-management"
    local log_file="$log_dir/install.log"

    mkdir -p "$log_dir"
}

make_sh_executable() {
    local target_dir="${1:-}"

    if [[ -z "$target_dir" ]]; then
        echo "Error: directory argument required" >&2
        return 1
    fi

    if [[ ! -d "$target_dir" ]]; then
        echo "Error: '$target_dir' is not a directory" >&2
        return 1
    fi

    # Find all .sh files safely, handling spaces and special characters
    find "$target_dir" -type f -name "*.sh" -print0 |
        while IFS= read -r -d '' file; do
            if [[ ! -x "$file" ]]; then
                chmod +x "$file"
            fi
        done
}

main() {
    require_root

    local script_dir
    script_dir="$(resolve_script_dir)"

    local install_dir="${1:-/opt/btrfs-management}"
    install_dir="$(readlink -f "$install_dir" 2>/dev/null || echo "$install_dir")"

    log "Installing BTRFS Management"
    log "Project root: $script_dir"
    log "Install destination: $install_dir"

    safe_copy_project "$script_dir" "$install_dir"

    ensure_symlink \
        "$install_dir/btrfs-management.sh" \
        "/usr/bin/btrfs-management"

    ensure_config "$install_dir"
    make_sh_executable "$install_dir"
    ensure_log_dir

    log "Installation completed successfully."
}

main "$@"