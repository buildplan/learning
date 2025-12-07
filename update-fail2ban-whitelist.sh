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
#   Changes are lost on server reboot (which is safest for dynamic IPs).
#
# SETUP INSTRUCTIONS (REMOTE VPS):
#   1. SSH into the server and find the correct path:
#      which fail2ban-client
#      (Update the script variable FAIL2BAN_CMD if it is not /usr/bin/fail2ban-client)
#
#   2. Edit permissions:
#      sudo visudo
#
#   3. Add the following lines at the VERY BOTTOM of the file.
#      (Putting them at the bottom ensures they are not overridden by group rules).
#      Replace 'your_user' with the actual username used in the script.
#
#      Defaults:your_user !requiretty
#      your_user ALL=(root) NOPASSWD: /usr/bin/fail2ban-client
#
# SETUP INSTRUCTIONS (LOCAL MACHINE):
#   1. Ensure 'curl' is installed.
#   2. Setup SSH Key authentication (passwordless login) to the VPS.
#   3. Add this script to a Cron job or LaunchAgent to run hourly.
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
VPS_HOST="name_or_ip"           # Hostname OR IP address
VPS_PORT="22"                   # Custom SSH port (default is 22)
VPS_USER="vps_user"             # VPS User
SSH_KEY="$HOME/.ssh/id_ed25519" # Key for SSH

# List your active jails here, space separated.
JAILS="sshd ufw-probes"

# Config for Notifications
NTFY_ENABLED=1
NTFY_SERVER="https://ntfy.sh"
NTFY_TOPIC="topic"
NTFY_TOKEN="tk_xxxxxxxxx"

# Local State Storage
STATE_DIR="$HOME/.config/fail2ban-whitelist"
STATE_FILE="$STATE_DIR/ip.state"
LOG_FILE="$STATE_DIR/update.log"

# Remote commands (Must match sudoers NOPASSWD path exactly)
FAIL2BAN_CMD="/usr/bin/fail2ban-client"

# --- Helpers ---

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"
}

get_ipv4() {
    for url in \
        "https://api.ipify.org" \
        "https://ifconfig.me/ip" \
        "https://icanhazip.com" \
        "https://ip.me"
    do
        ipv4=$(curl -4 -s -m 5 "$url" 2>/dev/null)
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
    ipv6=$(curl -6 -s -m 5 "https://ifconfig.co" 2>/dev/null)
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
    if [ -n "$OLD_IPV4" ] && [ "$OLD_IPV4" != "$CURRENT_IPV4" ]; then
        remote_script="${remote_script} sudo $FAIL2BAN_CMD set $jail delignoreip $OLD_IPV4 || true;"
    fi
    if [ -n "$CURRENT_IPV4" ]; then
        remote_script="${remote_script} sudo $FAIL2BAN_CMD set $jail addignoreip $CURRENT_IPV4;"
    fi

    if [ -n "$OLD_IPV6" ] && [ "$OLD_IPV6" != "$CURRENT_IPV6" ]; then
        remote_script="${remote_script} sudo $FAIL2BAN_CMD set $jail delignoreip $OLD_IPV6 || true;"
    fi
    if [ -n "$CURRENT_IPV6" ]; then
        remote_script="${remote_script} sudo $FAIL2BAN_CMD set $jail addignoreip $CURRENT_IPV6;"
    fi
done

if [ -z "$remote_script" ]; then
    log "No remote commands needed."
    exit 0
fi

# 5. Execute via SSH
SSH_OPTS="-q -o ConnectTimeout=10 -o BatchMode=yes"

if [ -n "$SSH_KEY" ] && [ -f "$SSH_KEY" ]; then
    SSH_OPTS="$SSH_OPTS -i $SSH_KEY"
fi
if [ -n "$VPS_PORT" ]; then
    SSH_OPTS="$SSH_OPTS -p $VPS_PORT"
fi

# shellcheck disable=SC2086,SC2029
if ssh $SSH_OPTS "$VPS_USER@$VPS_HOST" "sh -c '$remote_script'"; then
    log "SUCCESS: Updated $JAILS. Old: $OLD_IPV4|$OLD_IPV6 -> New: $CURRENT_IPV4|$CURRENT_IPV6"
    printf '%s %s\n' "$CURRENT_IPV4" "$CURRENT_IPV6" > "$STATE_FILE"

    send_ntfy "✅ Whitelist Updated
    Target: $VPS_HOST:$VPS_PORT
    Jails: $JAILS
    Old v4: ${OLD_IPV4:-None}
    New v4: ${CURRENT_IPV4:-None}
    Old v6: ${OLD_IPV6:-None}
    New v6: ${CURRENT_IPV6:-None}" "3"
    exit 0
else
    log "ERROR: SSH connection or remote execution failed."
    send_ntfy "❌ Fail2ban: SSH update failed for $VPS_HOST:$VPS_PORT" "5"
    exit 1
fi
