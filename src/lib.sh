require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        error "This installer must be run as root."
    fi
}

add_exit_trap() {
    local new="$1"
    local existing
    existing="$(trap -p EXIT | awk -F"'" '{print $2}')"

    if [[ -n "$existing" ]]; then
        trap "$existing; $new" EXIT
    else
        trap "$new" EXIT
    fi
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
            export DEBIAN_FRONTEND=noninteractive 
            apt-get update
            apt-get install -y "${missing[@]}"
        fi
    else
        warn "Distribution '$distro' is not supported. Future commands may fail."
    fi
}

# Global array used to track exported variables
# Do NOT make local, must persist between calls
__LOADED_ENV_VARS=()

load_env_file() {
    local file="$1"

    if [[ -z "$file" ]]; then
        echo "load_env_file: missing file argument" >&2
        return 1
    fi

    if [[ ! -f "$file" ]]; then
        echo "load_env_file: file not found: $file" >&2
        return 1
    fi

    # -----------------------------
    # Parse file safely
    # -----------------------------
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Trim leading/trailing whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        # Skip empty lines
        [[ -z "$line" ]] && continue

        # Skip full-line comments
        [[ "$line" =~ ^# ]] && continue

        # Only allow valid variable assignments
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            local var_name="${BASH_REMATCH[1]}"
            local var_value="${BASH_REMATCH[2]}"

            # Remove surrounding quotes if present
            if [[ "$var_value" =~ ^\"(.*)\"$ ]]; then
                var_value="${BASH_REMATCH[1]}"
            elif [[ "$var_value" =~ ^\'(.*)\'$ ]]; then
                var_value="${BASH_REMATCH[1]}"
            fi

            # Export variable
            export "$var_name=$var_value"

            # Track for future cleanup
            __LOADED_ENV_VARS+=("$var_name")
        else
            warn "load_env_file: invalid line ignored: $line"
        fi

    done < "$file"
}

reset_env() {
    if ((${#__LOADED_ENV_VARS[@]} > 0)); then
        for var in "${__LOADED_ENV_VARS[@]}"; do
            unset "$var"
        done
    fi
    __LOADED_ENV_VARS=()
}

send_mail() {
    set -euo pipefail
    local template="$1"

    # Source the SMTP config
    if [[ -f /etc/btrfs-management/smtp.config ]]; then
        load_env_file /etc/btrfs-management/smtp.config
    else
        echo "SMTP config not found at /etc/btrfs-management/smtp.config" >&2
        return 1
    fi

    # Make sure template file exists
    if [[ ! -f "./msmtp_templates/$template.tmpl" ]]; then
        echo "Email template not found: ./msmtp_templates/$template.tmpl" >&2
        return 1
    fi

    # Create a secure temporary msmtp config
    local tmp_msmtp
    tmp_msmtp=$(mktemp)
    chmod 600 "$tmp_msmtp"
    add_exit_trap "rm -f '$tmp_msmtp'"

    cat >"$tmp_msmtp" <<EOF
defaults
auth           $SMTP_AUTH
tls            $SMTP_TLS
account default
host           $SMTP_HOST
port           $SMTP_PORT
from           $SMTP_FROM
user           $SMTP_USER
password       $SMTP_PASS
EOF

    export HOSTNAME

    {
        # Render template with envsubst
        envsubst < "./msmtp_templates/$template.tmpl"

        # Pipe stdin into msmtp with rendered message
        # The message body comes from stdin, so we append stdin after the rendered headers
        if [ ! -t 0 ]; then
            # stdin is NOT a terminal (likely piped or redirected)
            cat
        fi
    } | msmtp -C "$tmp_msmtp" -t
}

source ./src/lib/logging.sh