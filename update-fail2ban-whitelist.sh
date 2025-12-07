#!/bin/sh
# shellcheck shell=sh
#
# ==============================================================================
# FAIL2BAN DYNAMIC WHITELIST UPDATER | update-fail2ban-whitelist.sh
# ==============================================================================
#
# PURPOSE:
#   Updates Fail2ban 'ignoreip' on a remote VPS with your current dynamic IP.
#   It updates the running process (memory), not the configuration file (disk).
#
# SETUP INSTRUCTIONS:
#   1. ON REMOTE SERVER (VPS):
#      Run: sudo visudo
#      Add this line (replace 'your_user' with the actual username used below):
#      your_user ALL=(root) NOPASSWD: /usr/bin/fail2ban-client
#
#   2. ON LOCAL MACHINE:
#      Ensure you have 'curl' installed.
#      Configure SSH Key authentication (passwordless login) to the VPS.
#
# USAGE:
#   ./update-fail2ban-whitelist.sh
#
# VERIFICATION:
#   Do NOT check /etc/fail2ban/jail.local (it will not change).
#   Run this on the VPS to see the active whitelist in memory:
#      sudo fail2ban-client get sshd ignoreip
#
# FORCE UPDATE:
#   To force the script to run even if your IP hasn't changed:
#      rm ~/.config/fail2ban-whitelist/ip.state
#
# ==============================================================================

set -u # Exit if variables are undefined

# --- Configuration ---
VPS_HOST="vps_host"  # vps hostname from ~/.ssh/config
VPS_USER="user_name"
SSH_KEY="$HOME/.ssh/id_ed25519"

# List your active jails here, space separated.
# e.g. "sshd ufw-probes nginx-http-auth"
JAILS="sshd"

# Config for Notifications
NTFY_ENABLED=0
NTFY_SERVER="https://ntfy.sh"
NTFY_TOPIC="your-topic"
NTFY_TOKEN=""  # Bearer token if required

# Local State Storage
STATE_DIR="$HOME/.config/fail2ban-whitelist"
STATE_FILE="$STATE_DIR/ip.state"
LOG_FILE="$STATE_DIR/update.log"

# Remote commands (Must match sudoers NOPASSWD path exactly)
FAIL2BAN_CMD="/usr/bin/fail2ban-client"

# --- Helpers ---

log() {
    # Appends timestamped message to log
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"
}

get_ipv4() {
    # Tries multiple services to get IPv4
    for url in \
        "https://api.ipify.org" \
        "https://ifconfig.me/ip" \
        "https://icanhazip.com" \
        "https://ip.me"
    do
        # curl: -4 force ipv4, -s silent, -m 5 max time
        ipv4=$(curl -4 -s -m 5 "$url" 2>/dev/null)

        # Simple validation: checks for 3 dots and numbers
        case "$ipv4" in
            *[0-9].*[0-9].*[0-9].*[0-9])
                printf '%s' "$ipv4"
                return 0
                ;;
        esac
    done
    return 1
}

get_ipv6() {
    # Tries to get IPv6
    ipv6=$(curl -6 -s -m 5 "https://ifconfig.co" 2>/dev/null)
    # Validate it contains a colon
    case "$ipv6" in
        *:*)
            printf '%s' "$ipv6"
            return 0
            ;;
    esac
    return 1
}

send_ntfy() {
    message="$1"
    priority="${2:-3}"

    if [ "$NTFY_ENABLED" != "1" ] || [ -z "$NTFY_SERVER" ] || [ -z "$NTFY_TOPIC" ]; then
        return 0
    fi

    url="$NTFY_SERVER/$NTFY_TOPIC"
    title="Fail2ban Whitelist"

    # Construct headers
    if [ -n "$NTFY_TOKEN" ]; then
        curl -s \
            -H "Authorization: Bearer $NTFY_TOKEN" \
            -H "Title: $title" \
            -H "X-Priority: $priority" \
            -d "$message" \
            "$url" >/dev/null 2>&1
    else
        curl -s \
            -H "Title: $title" \
            -H "X-Priority: $priority" \
            -d "$message" \
            "$url" >/dev/null 2>&1
    fi
}

# --- Main Logic ---

mkdir -p "$STATE_DIR"

# 1. Detect IPs
CURRENT_IPV4=$(get_ipv4) || CURRENT_IPV4=""
CURRENT_IPV6=$(get_ipv6) || CURRENT_IPV6=""

if [ -z "$CURRENT_IPV4" ] && [ -z "$CURRENT_IPV6" ]; then
    log "ERROR: Could not detect any public IP."
    send_ntfy "❌ Fail2ban: Could not detect any public IP" "5"
    exit 1
fi

# 2. Read Previous State
OLD_IPV4=""
OLD_IPV6=""
if [ -f "$STATE_FILE" ]; then
    # Read first line, safely split by space
    read -r line < "$STATE_FILE" 2>/dev/null || line=""
    OLD_IPV4=$(printf '%s' "$line" | cut -d' ' -f1)
    OLD_IPV6=$(printf '%s' "$line" | cut -d' ' -f2)
fi

# 3. Compare State
if [ "$CURRENT_IPV4" = "$OLD_IPV4" ] && [ "$CURRENT_IPV6" = "$OLD_IPV6" ]; then
    log "IP unchanged. v4:$CURRENT_IPV4 v6:$CURRENT_IPV6"
    exit 0
fi

# 4. Build Remote Command

remote_script=""

for jail in $JAILS; do
    # Remove OLD IPv4
    if [ -n "$OLD_IPV4" ] && [ "$OLD_IPV4" != "$CURRENT_IPV4" ]; then
        remote_script="${remote_script} sudo $FAIL2BAN_CMD set $jail delignoreip $OLD_IPV4 >/dev/null 2>&1 || true;"
    fi
    # Add NEW IPv4
    if [ -n "$CURRENT_IPV4" ]; then
        remote_script="${remote_script} sudo $FAIL2BAN_CMD set $jail addignoreip $CURRENT_IPV4 >/dev/null 2>&1;"
    fi

    # Remove OLD IPv6
    if [ -n "$OLD_IPV6" ] && [ "$OLD_IPV6" != "$CURRENT_IPV6" ]; then
        remote_script="${remote_script} sudo $FAIL2BAN_CMD set $jail delignoreip $OLD_IPV6 >/dev/null 2>&1 || true;"
    fi
    # Add NEW IPv6
    if [ -n "$CURRENT_IPV6" ]; then
        remote_script="${remote_script} sudo $FAIL2BAN_CMD set $jail addignoreip $CURRENT_IPV6 >/dev/null 2>&1;"
    fi
done

if [ -z "$remote_script" ]; then
    log "No remote commands needed."
    exit 0
fi

# 5. Execute via SSH
SSH_OPTS="-o ConnectTimeout=10 -o BatchMode=yes"
if [ -n "$SSH_KEY" ] && [ -f "$SSH_KEY" ]; then
    SSH_OPTS="$SSH_OPTS -i $SSH_KEY"
fi

# shellcheck disable=SC2086,SC2029
if ssh $SSH_OPTS "$VPS_USER@$VPS_HOST" "sh -c '$remote_script'"; then
    log "SUCCESS: Updated $JAILS. Old: $OLD_IPV4|$OLD_IPV6 -> New: $CURRENT_IPV4|$CURRENT_IPV6"

    # Save new state
    printf '%s %s\n' "$CURRENT_IPV4" "$CURRENT_IPV6" > "$STATE_FILE"

    send_ntfy "✅ Whitelist Updated
    Jails: $JAILS
    Old v4: ${OLD_IPV4:-None}
    New v4: ${CURRENT_IPV4:-None}
    Old v6: ${OLD_IPV6:-None}
    New v6: ${CURRENT_IPV6:-None}" "3"
    exit 0
else
    log "ERROR: SSH connection or remote execution failed."
    send_ntfy "❌ Fail2ban: SSH update failed for $VPS_HOST" "5"
    exit 1
fi
