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
VPS_HOST="VPS"               # VPS hostname or IP
SSH_USER="admin"             # SSH user on VPS
SSH_PORT=""                  # Leave empty for default 22, or set custom port (e.g. "5555")
SSH_KEY=""                   # SSH KEY PATH (Optional), leave empty to use default SSH behavior
                             # If setting a path, use $HOME instead of ~, e.g.: "$HOME/.ssh/my_custom_key"

# NAME OF THE DEDICATED LIST
# This must match the list at CrowdSec
ALLOWLIST_NAME="home_dynamic_ips"

DESC_V4="home dynamic IPv4"
DESC_V6="home dynamic IPv6"

# ntfy
NTFY_ENABLED="yes"
NTFY_URL="https://ntfy.example.com/topic-name"
NTFY_TOKEN="YOUR_NTFY_TOKEN_HERE"

# IPv6 toggle
HANDLE_IPV6="no"

# --- Helpers ---

ntfy_send() {
    _TITLE="$1"
    _MSG="$2"
    [ "$NTFY_ENABLED" = "yes" ] || return 0
    curl -s -X POST \
        -H "Authorization: Bearer $NTFY_TOKEN" \
        -H "Title: $_TITLE" \
        -d "$_MSG" \
        "$NTFY_URL" >/dev/null 2>&1 || :
}

get_public_ipv4() {
    _IP=$(curl -4 -s https://ip.me 2>/dev/null || curl -4 -s https://api.ipify.org 2>/dev/null)
    _IP=$(printf '%s\n' "$_IP" | tr -d ' \t\r\n')
    case "$_IP" in
        *.*.*.*) printf '%s\n' "$_IP" ;;
        *) printf '' ;;
    esac
}

get_public_ipv6() {
    _IP=$(curl -6 -s https://api64.ipify.org 2>/dev/null || curl -6 -s https://ip.me 2>/dev/null)
    _IP=$(printf '%s\n' "$_IP" | tr -d ' \t\r\n')
    case "$_IP" in
        *:*:*) printf '%s\n' "$_IP" ;;
        *) printf '' ;;
    esac
}

in_list() {
    _NEEDLE="$1"
    _LIST="$2"
    printf '%s\n' "$_LIST" | grep -Fqx "$_NEEDLE"
}

# --- Preparation ---

# Build the SSH Key Flag dynamically.
SSH_KEY_FLAG=""
if [ -n "$SSH_KEY" ]; then
    SSH_KEY_FLAG="-i $SSH_KEY"
fi

# --- Main Execution ---

# 1. Get Local IPs
CURRENT_IPv4=$(get_public_ipv4)
if [ -z "$CURRENT_IPv4" ]; then
    ntfy_send "CrowdSec Updater: Failure" "Could not detect local IPv4."
    exit 1
fi

CURRENT_IPv6=""
if [ "$HANDLE_IPV6" = "yes" ]; then
    CURRENT_IPv6=$(get_public_ipv6)
    if [ -z "$CURRENT_IPv6" ]; then
        ntfy_send "CrowdSec Updater: Warning" "IPv6 is enabled in settings, but no public IPv6 address could be detected."
    fi
fi

# 2. Fetch the DEDICATED allowlist content
REMOTE_OUTPUT=$(
  ssh -q -o BatchMode=yes -o ConnectTimeout=10 $SSH_KEY_FLAG -p "${SSH_PORT:-22}" "${SSH_USER}@${VPS_HOST}" \
    "docker exec crowdsec cscli allowlists inspect ${ALLOWLIST_NAME} -o human 2>/dev/null" \
    || printf ''
)

REMOTE_IPS=$(printf '%s\n' "$REMOTE_OUTPUT" | grep -E '^[0-9a-fA-F:.]' | awk '{print $1}')

UPDATED="no"
ADDED_IPS=""

# Helper to clear the dedicated list
clear_remote_list() {
    [ -z "$REMOTE_IPS" ] && return 0
    for OLD_IP in $REMOTE_IPS; do
        ssh -q -o BatchMode=yes $SSH_KEY_FLAG -p "${SSH_PORT:-22}" "${SSH_USER}@${VPS_HOST}" \
           "docker exec crowdsec cscli allowlists remove ${ALLOWLIST_NAME} ${OLD_IP}" >/dev/null 2>&1 || :
    done
}

# --- Check IPv4 ---
if ! in_list "$CURRENT_IPv4" "$REMOTE_IPS"; then
    clear_remote_list
    if ssh -q -o BatchMode=yes $SSH_KEY_FLAG -p "${SSH_PORT:-22}" "${SSH_USER}@${VPS_HOST}" \
        "docker exec crowdsec cscli allowlists add ${ALLOWLIST_NAME} ${CURRENT_IPv4} -d '${DESC_V4}'"; then
        UPDATED="yes"
        ADDED_IPS="$CURRENT_IPv4"
    else
        ntfy_send "CrowdSec Updater: Error" "Failed to add IPv4 to $VPS_HOST"
        exit 1
    fi
fi

# --- Check IPv6 (Optional) ---
if [ "$HANDLE_IPV6" = "yes" ] && [ -n "$CURRENT_IPv6" ]; then
    if ! in_list "$CURRENT_IPv6" "$REMOTE_IPS"; then
        if ssh -q -o BatchMode=yes $SSH_KEY_FLAG -p "${SSH_PORT:-22}" "${SSH_USER}@${VPS_HOST}" \
            "docker exec crowdsec cscli allowlists add ${ALLOWLIST_NAME} ${CURRENT_IPv6} -d '${DESC_V6}'"; then
            UPDATED="yes"
            if [ -n "$ADDED_IPS" ]; then ADDED_IPS="$ADDED_IPS, $CURRENT_IPv6"; else ADDED_IPS="$CURRENT_IPv6"; fi
        fi
    fi
fi

# 3. Notification
if [ "$UPDATED" = "yes" ]; then
    ntfy_send "CrowdSec IP Updated" "Updated allowlist '${ALLOWLIST_NAME}'. New IP: $ADDED_IPS"
fi

exit 0
