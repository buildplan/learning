#!/bin/sh

# --- Config ---
# SSH target (use Host from ~/.ssh/config)
VPS_HOST="vps_host"              # e.g. Host alias in ~/.ssh/config
VPS_USER="vps_user_name"
SSH_KEY="$HOME/.ssh/id_ed25519"  # or empty to use default key
JAIL_NAME="DEFAULT"

# ntfy configuration (all optional)
NTFY_ENABLED=1
NTFY_SERVER="https://ntfy.sh"    # or your self-hosted server
NTFY_TOPIC="your-topic"
NTFY_TOKEN=""                    # Bearer token set to tk_... for Bearer auth

# Local state
STATE_DIR="$HOME/.config/fail2ban-whitelist"
STATE_FILE="$STATE_DIR/ip.state"
LOG_FILE="$STATE_DIR/update.log"

# --- Helpers ---
log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"
}

get_ipv4() {
    # Try several services, IPv4 only
    ipv4=""
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
    # Optional IPv6 detection
    ipv6=$(curl -6 -s --max-time 5 "https://ifconfig.co" 2>/dev/null)
    if [ -n "$ipv6" ]; then
        printf '%s\n' "$ipv6"
        return 0
    fi
    return 1
}

send_ntfy() {
    message=$1
    priority=$2

    if [ "$NTFY_ENABLED" != "1" ]; then
        return 0
    fi

    if [ -z "$priority" ]; then
        priority="3"    # normal priority
    fi

    if [ -z "$NTFY_SERVER" ] || [ -z "$NTFY_TOPIC" ]; then
        return 0
    fi

    url="$NTFY_SERVER/$NTFY_TOPIC"

    if [ -n "$NTFY_TOKEN" ]; then
        # Bearer token auth (recommended) [web:51][web:61]
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

CURRENT_IPV4=""
CURRENT_IPV6=""

if CURRENT_IPV4=$(get_ipv4); then
    :
else
    CURRENT_IPV4=""
fi

if CURRENT_IPV6=$(get_ipv6); then
    :
else
    CURRENT_IPV6=""
fi

if [ -z "$CURRENT_IPV4" ] && [ -z "$CURRENT_IPV6" ]; then
    log "ERROR: could not detect any public IP"
    send_ntfy "❌ Fail2ban whitelist: could not detect any public IP" "5"
    exit 1
fi

OLD_IPV4=""
OLD_IPV6=""

if [ -f "$STATE_FILE" ]; then
    # File format: "ipv4 ipv6"
    OLD_IPV4=$(cut -d' ' -f1 "$STATE_FILE")
    OLD_IPV6=$(cut -d' ' -f2 "$STATE_FILE")
fi

if [ "$CURRENT_IPV4" = "$OLD_IPV4" ] && [ "$CURRENT_IPV6" = "$OLD_IPV6" ]; then
    log "IP unchanged: v4=$CURRENT_IPV4 v6=$CURRENT_IPV6"
    exit 0
fi

# Build remote command using fail2ban-client addignoreip/delignoreip [web:74][web:76]
remote_cmd=""

if [ -n "$OLD_IPV4" ] && [ "$OLD_IPV4" != "$CURRENT_IPV4" ]; then
    remote_cmd=$remote_cmd"sudo fail2ban-client set $JAIL_NAME delignoreip $OLD_IPV4 2>/dev/null || true; "
fi

if [ -n "$CURRENT_IPV4" ]; then
    remote_cmd=$remote_cmd"sudo fail2ban-client set $JAIL_NAME addignoreip $CURRENT_IPV4; "
fi

if [ -n "$OLD_IPV6" ] && [ "$OLD_IPV6" != "$CURRENT_IPV6" ]; then
    remote_cmd=$remote_cmd"sudo fail2ban-client set $JAIL_NAME delignoreip $OLD_IPV6 2>/dev/null || true; "
fi

if [ -n "$CURRENT_IPV6" ]; then
    remote_cmd=$remote_cmd"sudo fail2ban-client set $JAIL_NAME addignoreip $CURRENT_IPV6; "
fi

if [ -z "$remote_cmd" ]; then
    log "Nothing to update on server"
    exit 0
fi

SSH_OPTS=""
if [ -n "$SSH_KEY" ]; then
    SSH_OPTS="-i $SSH_KEY"
fi

# Run remote update
if ssh $SSH_OPTS "$VPS_USER@$VPS_HOST" "$remote_cmd"; then
    log "Updated fail2ban ignoreip: old v4=$OLD_IPV4 v6=$OLD_IPV6; new v4=$CURRENT_IPV4 v6=$CURRENT_IPV6"
    printf '%s %s\n' "$CURRENT_IPV4" "$CURRENT_IPV6" > "$STATE_FILE"
    send_ntfy "✅ Whitelist updated\nOld v4: ${OLD_IPV4:-none}\nNew v4: ${CURRENT_IPV4:-none}\nOld v6: ${OLD_IPV6:-none}\nNew v6: ${CURRENT_IPV6:-none}" "4"
    exit 0
else
    log "ERROR: SSH to $VPS_HOST failed"
    send_ntfy "❌ Fail2ban whitelist: SSH to $VPS_HOST failed" "5"
    exit 1
fi
