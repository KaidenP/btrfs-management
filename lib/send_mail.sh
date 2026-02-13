send_mail() {
    set -euo pipefail

    # Require a template argument
    local template="$1"
    shift

    # Source the SMTP config
    if [[ -f /etc/btrfs-management/smtp.config ]]; then
        # shellcheck disable=SC1091
        export $(grep -v '^#' /etc/btrfs-management/smtp.config | xargs)
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
    trap "rm -f '$tmp_msmtp'" EXIT

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
        cat
    } | msmtp -C "$tmp_msmtp" -t
}