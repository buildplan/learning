#!/bin/sh
# shellcheck shell=sh

# --- Config ---
VPS_HOST="vps_host"
VPS_USER="vps_user_name"
SSH_KEY="$HOME/.ssh/id_ed25519"
JAIL_NAME="DEFAULT"

NTFY_ENABLED=1
NTFY_SERVER="https://ntfy.sh"
NTFY_TOPIC="your-topic"
NTFY_TOKEN=""  # Bearer token: tk_...

STATE_DIR="$HOME/.config/fail2ban-whitelist"
STATE_FILE="$STATE_DIR/ip.state"
LOG_FILE="$STATE_DIR/update.log"

# --- Helpers ---
log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"
}

get_ipv4() {
    for url in \
        "https://ip.me" \
        "https://ifconfig.me" \
        "https://icanhazip.com" \
        "https://api.ipify.org"
    do
        ipv4=$(curl -4 -s --max-time 5 "$url" 2>/dev/null)
        case "$ipv4" in
            '' ) ;;
            *.*.*.* )
                printf '%s\n' "$ipv4"
                return 0
                ;;
        esac
    done
    return 1
}

get_ipv6() {
    ipv6=$(curl -6 -s --max-time 5 "https://ifconfig.co" 2>/dev/null)
    if [ -n "$ipv6" ]; then
        printf '%s\n' "$ipv6"
        return 0
    fi
    return 1
}

send_ntfy() {
    message=$1
    priority=${2:-3}

    if [ "$NTFY_ENABLED" != "1" ] || [ -z "$NTFY_SERVER" ] || [ -z "$NTFY_TOPIC" ]; then
        return 0
    fi

    url="$NTFY_SERVER/$NTFY_TOPIC"

    if [ -n "$NTFY_TOKEN" ]; then
        curl -s \
            -H "Authorization: Bearer $NTFY_TOKEN" \
            -H "Title: Fail2ban whitelist" \
            -H "X-Priority: $priority" \
            -d "$message" \
            "$url" >/dev/null 2>&1
    else
        curl -s \
            -H "Title: Fail2ban whitelist" \
            -H "X-Priority: $priority" \
            -d "$message" \
            "$url" >/dev/null 2>&1
    fi
}

# --- Main ---
mkdir -p "$STATE_DIR"

# Simplify IP detection
CURRENT_IPV4=$(get_ipv4 || true)
CURRENT_IPV6=$(get_ipv6 || true)

if [ -z "$CURRENT_IPV4" ] && [ -z "$CURRENT_IPV6" ]; then
    log "ERROR: could not detect any public IP"
    send_ntfy "❌ Fail2ban whitelist: could not detect any public IP" "5"
    exit 1
fi

# Read old IPs
OLD_IPV4=""
OLD_IPV6=""
if [ -f "$STATE_FILE" ]; then
    OLD_IPV4=$(cut -d' ' -f1 "$STATE_FILE" 2>/dev/null)
    OLD_IPV6=$(cut -d' ' -f2 "$STATE_FILE" 2>/dev/null)
fi

# Check if unchanged
if [ "$CURRENT_IPV4" = "$OLD_IPV4" ] && [ "$CURRENT_IPV6" = "$OLD_IPV6" ]; then
    log "IP unchanged: v4=$CURRENT_IPV4 v6=$CURRENT_IPV6"
    exit 0
fi

# Build remote commands safely
remote_cmd=""
[ -n "$OLD_IPV4" ] && [ "$OLD_IPV4" != "$CURRENT_IPV4" ] && \
    remote_cmd="${remote_cmd}sudo fail2ban-client set $JAIL_NAME delignoreip $OLD_IPV4 2>/dev/null || true; "
[ -n "$CURRENT_IPV4" ] && \
    remote_cmd="${remote_cmd}sudo fail2ban-client set $JAIL_NAME addignoreip $CURRENT_IPV4; "
[ -n "$OLD_IPV6" ] && [ "$OLD_IPV6" != "$CURRENT_IPV6" ] && \
    remote_cmd="${remote_cmd}sudo fail2ban-client set $JAIL_NAME delignoreip $OLD_IPV6 2>/dev/null || true; "
[ -n "$CURRENT_IPV6" ] && \
    remote_cmd="${remote_cmd}sudo fail2ban-client set $JAIL_NAME addignoreip $CURRENT_IPV6; "

if [ -z "$remote_cmd" ]; then
    log "Nothing to update on server"
    exit 0
fi

# SSH options handling
SSH_CMD="ssh"
if [ -n "$SSH_KEY" ] && [ -f "$SSH_KEY" ]; then
    SSH_CMD="ssh -i $SSH_KEY"
fi

# Execute remote update
if $SSH_CMD "$VPS_USER@$VPS_HOST" "$remote_cmd"; then
    log "Updated fail2ban ignoreip: old v4=$OLD_IPV4 v6=$OLD_IPV6; new v4=$CURRENT_IPV4 v6=$CURRENT_IPV6"
    printf '%s %s\n' "$CURRENT_IPV4" "$CURRENT_IPV6" > "$STATE_FILE"
    send_ntfy "✅ Whitelist updated\nOld v4: ${OLD_IPV4:-none}\nNew v4: ${CURRENT_IPV4:-none}\nOld v6: ${OLD_IPV6:-none}\nNew v6: ${CURRENT_IPV6:-none}" "4"
    exit 0
else
    log "ERROR: SSH to $VPS_HOST failed"
    send_ntfy "❌ Fail2ban whitelist: SSH to $VPS_HOST failed" "5"
    exit 1
fi
