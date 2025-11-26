#!/bin/sh

# ==============================================================================
# CROWDSEC DYNAMIC HOME IP UPDATER
# ==============================================================================
#
# PURPOSE:
#   Detects local public IP and adds it to a CrowdSec allowlist on a remote VPS.
#
#   *** CRITICAL CONFIGURATION WARNING ***
#   This script uses a "Self-Cleaning" strategy. If the IPv4 changes, it
#   WIPES ALL ENTRIES in the target allowlist to prevent stale IPs piling up.
#
#   1. DO NOT target your main 'trusted_ips' list if it contains other static
#      IPs (like office, servers, or friends). They will be deleted.
#   2. ALWAYS use a dedicated list (e.g., 'home_dynamic_ips') just for this script.
#
# PREREQUISITES (Run once):
#   1. SSH Keys: Ensure passwordless login works.
#   2. Create List: Run this on the VPS to create the dedicated list:
#      docker exec crowdsec cscli allowlists create home_dynamic_ips
#
# CRON EXAMPLE (Run every 15 mins):
#   */15 * * * * /path/to/this_script.sh >/dev/null 2>&1
# ==============================================================================

set -u

# --- Configuration ---

# VPS / CrowdSec Details
VPS_HOST="VPS_IP_OR_HOSTNAME" # VPS hostname or IP
SSH_USER="admin"              # SSH user
SSH_PORT="22"                 # Default 22, or set custom port (e.g. "5555")
SSH_KEY=""                    # Leave empty for default or e.g.: "$HOME/.ssh/my_custom_key"


The script will CREATE this list if it does not exist.
ALLOWLIST_NAME="home_dynamic_ips"

DESC_V4="home dynamic IPv4"
DESC_V6="home dynamic IPv6"

# Notifications
NTFY_ENABLED="yes"
NTFY_URL="https://ntfy.example.com/topic"
NTFY_TOKEN="YOUR_TOKEN"

# Settings
HANDLE_IPV6="no"

# --- Helpers ---

ntfy_send() {
    _TITLE="$1"
    _MSG="$2"
    [ "$NTFY_ENABLED" = "yes" ] || return 0
    if command -v curl >/dev/null 2>&1; then
        curl -s -X POST \
            -H "Authorization: Bearer $NTFY_TOKEN" \
            -H "Title: $_TITLE" \
            -d "$_MSG" \
            "$NTFY_URL" >/dev/null 2>&1 || :
    fi
}

get_public_ipv4() {
    _IP=$(curl -4 -s https://ip.me 2>/dev/null || curl -4 -s https://api.ipify.org 2>/dev/null)
    _IP=$(printf '%s\n' "$_IP" | tr -d '[:space:]')
    case "$_IP" in
        *.*.*.*) printf '%s\n' "$_IP" ;;
        *) printf '' ;;
    esac
}

get_public_ipv6() {
    _IP=$(curl -6 -s https://api64.ipify.org 2>/dev/null || curl -6 -s https://ip.me 2>/dev/null)
    _IP=$(printf '%s\n' "$_IP" | tr -d '[:space:]')
    case "$_IP" in
        *:*:*) printf '%s\n' "$_IP" ;;
        *) printf '' ;;
    esac
}

# --- Main Execution ---

# 1. Get Local IPs
CURRENT_IPv4=$(get_public_ipv4)

if [ -z "$CURRENT_IPv4" ]; then
    ntfy_send "CrowdSec Failure" "Could not detect local IPv4."
    exit 1
fi

CURRENT_IPv6=""
if [ "$HANDLE_IPV6" = "yes" ]; then
    CURRENT_IPv6=$(get_public_ipv6)
fi

# 2. Build SSH Command Prefix
SSH_CMD="ssh -q -o BatchMode=yes -o ConnectTimeout=10 -p ${SSH_PORT}"
if [ -n "$SSH_KEY" ]; then
    SSH_CMD="$SSH_CMD -i $SSH_KEY"
fi
SSH_CMD="$SSH_CMD ${SSH_USER}@${VPS_HOST}"

# 3. Fetch Remote List (With Auto-Creation)
REMOTE_CMD="docker exec crowdsec cscli allowlists inspect ${ALLOWLIST_NAME} -o human 2>/dev/null || docker exec crowdsec cscli allowlists create ${ALLOWLIST_NAME}"

REMOTE_OUTPUT=$($SSH_CMD "$REMOTE_CMD" || printf '')

# Parse IPs (grep ensures we only grab IP-looking lines, ignoring 'List created' messages)
REMOTE_IPS=$(printf '%s\n' "$REMOTE_OUTPUT" | grep -E '^[0-9a-fA-F:.]' | awk '{print $1}')

# 4. Logic Calculation
NEEDS_UPDATE="no"
COMMAND_BATCH=""
REMOVED_LOG=""
ADDED_LOG=""

# Check for STALE IPs (Remote IPs that are NOT current v4 or v6)
for r_ip in $REMOTE_IPS; do
    is_valid="no"
    [ "$r_ip" = "$CURRENT_IPv4" ] && is_valid="yes"
    [ "$r_ip" = "$CURRENT_IPv6" ] && is_valid="yes"

    if [ "$is_valid" = "no" ]; then
        NEEDS_UPDATE="yes"
        COMMAND_BATCH="${COMMAND_BATCH} docker exec crowdsec cscli allowlists remove ${ALLOWLIST_NAME} ${r_ip};"
        REMOVED_LOG="${REMOVED_LOG} ${r_ip}"
    fi
done

# Check for MISSING IPv4
if ! printf '%s\n' "$REMOTE_IPS" | grep -Fqx "$CURRENT_IPv4"; then
    NEEDS_UPDATE="yes"
    COMMAND_BATCH="${COMMAND_BATCH} docker exec crowdsec cscli allowlists add ${ALLOWLIST_NAME} ${CURRENT_IPv4} -d '${DESC_V4}';"
    ADDED_LOG="${ADDED_LOG} ${CURRENT_IPv4}"
fi

# Check for MISSING IPv6
if [ "$HANDLE_IPV6" = "yes" ] && [ -n "$CURRENT_IPv6" ]; then
    if ! printf '%s\n' "$REMOTE_IPS" | grep -Fqx "$CURRENT_IPv6"; then
        NEEDS_UPDATE="yes"
        COMMAND_BATCH="${COMMAND_BATCH} docker exec crowdsec cscli allowlists add ${ALLOWLIST_NAME} ${CURRENT_IPv6} -d '${DESC_V6}';"
        ADDED_LOG="${ADDED_LOG} ${CURRENT_IPv6}"
    fi
fi

# 5. Execute Update (if needed)
if [ "$NEEDS_UPDATE" = "yes" ]; then

    # Run the batch command in ONE SSH connection
    if $SSH_CMD "$COMMAND_BATCH"; then
        MSG="CrowdSec Updated."
        [ -n "$ADDED_LOG" ] && MSG="$MSG Added: $ADDED_LOG."
        [ -n "$REMOVED_LOG" ] && MSG="$MSG Removed: $REMOVED_LOG."

        ntfy_send "CrowdSec IP Updated" "$MSG"
    else
        ntfy_send "CrowdSec Error" "Failed to execute update on VPS."
        exit 1
    fi
fi

exit 0
