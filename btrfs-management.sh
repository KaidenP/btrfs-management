#!/usr/bin/env bash
# Strict mode for safer Bash scripting
set -euo pipefail

# Detect if the script was run with -x (debug/tracing)
if [[ "$-" == *x* ]]; then
    TRACE_MODE=1
else
    TRACE_MODE=0
fi

# ================================
# Helper Functions
# ================================

# Resolve the real directory of this script, even if run via symlink
get_script_dir() {
    local SOURCE="${BASH_SOURCE[0]}"
    while [ -L "$SOURCE" ]; do
        SOURCE="$(readlink "$SOURCE")"
    done
    echo "$(cd -P "$(dirname "$SOURCE")" && pwd)"
}


# Run a script, optionally propagating -x mode
run_script() {
    local script_path="$1"
    shift || true
    if [ "$TRACE_MODE" -eq 1 ]; then
        bash -x "$script_path" "$@"
    else
        "$script_path" "$@"
    fi
}

# Print help message
print_help() {
    echo "Usage: $0 <command> [args...]"
    echo
    echo "Commands:"
    echo "  reinstall       Run the install script"
    echo "  update          Pull latest changes and run install"
    
    # List all available commands in lib/command
    local cmd_dir="$SCRIPT_DIR/lib/command"
    if [ -d "$cmd_dir" ]; then
        for script in "$cmd_dir"/*.sh; do
            [ -f "$script" ] || continue
            local name
            name=$(basename "$script" .sh)
            # Ask each script for synopsis if it supports it
            if "$script" synopsis &>/dev/null; then
                local synopsis
                synopsis=$(run_script "$script" synopsis)
                echo "  $name       $synopsis"
            else
                echo "  $name"
            fi
        done
    fi
}

# ================================
# Main Script Logic
# ================================

# Change into the script's real directory
SCRIPT_DIR=$(get_script_dir)
cd "$SCRIPT_DIR"

# Ensure at least one argument is provided
if [ $# -lt 1 ]; then
    print_help
    exit 0
fi

COMMAND="$1"
shift || true  # Remaining arguments

case "$COMMAND" in
    reinstall)
        INSTALL_SCRIPT="$SCRIPT_DIR/install.sh"
        if [ ! -x "$INSTALL_SCRIPT" ]; then
            echo "Error: install.sh not found or not executable at $INSTALL_SCRIPT" >&2
            exit 1
        fi
        run_script "$INSTALL_SCRIPT"
        ;;

    update)
        if [ ! -d "$SCRIPT_DIR/.git" ]; then
            echo "Error: No git repository found in $SCRIPT_DIR" >&2
            exit 1
        fi
        echo "Updating repository..."
        git -C "$SCRIPT_DIR" pull
        INSTALL_SCRIPT="$SCRIPT_DIR/install.sh"
        if [ ! -x "$INSTALL_SCRIPT" ]; then
            echo "Error: install.sh not found or not executable at $INSTALL_SCRIPT" >&2
            exit 1
        fi
        run_script "$INSTALL_SCRIPT"
        ;;

    help|""|"-h"|"--help")
        print_help
        ;;

    *)
        CMD_SCRIPT="$SCRIPT_DIR/lib/command/$COMMAND.sh"
        if [ ! -x "$CMD_SCRIPT" ]; then
            echo "Error: Command script not found or not executable: $CMD_SCRIPT" >&2
            exit 1
        fi
        # Execute the command with remaining arguments
        run_script "$CMD_SCRIPT" "$@"
        exit $?  # Exit with the command's exit code
        ;;
esac
