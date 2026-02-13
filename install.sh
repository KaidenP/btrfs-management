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
    rsync -a --delete \
        --exclude='.vagrant/' \
        "$source_dir/" "$dest_dir/"
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
    shopt -s nullglob

    local install_dir="$1"
    local etc_dir="/etc/btrfs-management"
    
    mkdir -p "$etc_dir/volumes.d"

    # -----------------------------
    # Main configs
    # -----------------------------
    local configs_candidates=("$install_dir"/conf/*.config)
    local example_configs_candidates=("$install_dir"/conf/*.config.example)

    # Install real configs (overwrite)
    if ((${#configs_candidates[@]} > 0)); then
        for cfg in "${configs_candidates[@]}"; do
            local target="$etc_dir/$(basename "$cfg")"
            cp -f "$cfg" "$target"
            log "Installed config (overwritten if existed): $target"
        done
    fi

    # Install example configs only if matching real config does not exist
    if ((${#example_configs_candidates[@]} > 0)); then
        for example in "${example_configs_candidates[@]}"; do
            local target="$etc_dir/$(basename "$example" .example)"

            # Only install example if real config not installed
            if [[ ! -f "$target" ]]; then
                cp "$example" "$target"
                log "Installed example config: $target"
            fi
        done
    fi

    # Enforce secure permissions on smtp config if it exists
    local smtp_target="$etc_dir/smtp.config"
    if [[ -f "$smtp_target" ]]; then
        chown root:root "$smtp_target"
        chmod 0600 "$smtp_target"
    fi

    # -----------------------------
    # volumes.d configs
    # -----------------------------
    local volume_configs=("$install_dir"/conf/volumes.d/*.config)
    local volume_example="$install_dir/conf/volumes.d/volume.config.example"
    local volume_example_target="$etc_dir/volumes.d/volume.config.example"

    if ((${#volume_configs[@]} > 0)); then
        for cfg in "${volume_configs[@]}"; do
            local target="$etc_dir/volumes.d/$(basename "$cfg")"
            cp -f "$cfg" "$target"
            log "Installed volume config (overwritten if existed): $target"
        done
    fi

    if [[ -f "$volume_example" && ! -f "$volume_example_target" ]]; then
        cp "$volume_example" "$volume_example_target"
        log "Installed example volume config: $volume_example_target"
    fi

    shopt -u nullglob
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

PACKAGES_UBUNTU="btrfs-progs msmtp"
ensure_packages() {
    # Detect distribution
    local distro
    if [ -r /etc/os-release ]; then
        distro=$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
    else
        warn "Cannot detect Linux distribution. Future commands may fail."
        return 1
    fi

    # If Ubuntu, install packages; else warn
    if [ "$distro" = "ubuntu" ]; then
        # Collect missing packages
        local missing=()
        for pkg in $PACKAGES_UBUNTU; do
            if ! dpkg -s "$pkg" &>/dev/null; then
                missing+=("$pkg")
            fi
        done

        # Install missing packages if any
        if [ ${#missing[@]} -gt 0 ]; then
            sudo apt-get update
            sudo apt-get install -y "${missing[@]}"
        fi
    else
        warn "Distribution '$distro' is not supported. Future commands may fail."
    fi
}

main() {
    require_root
    ensure_packages

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