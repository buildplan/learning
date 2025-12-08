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
SSH_PORT=""                  # Leave empty for default 22
SSH_KEY=""                   # SSH KEY PATH (Optional)

# CrowdSec Allow List
ALLOWLIST_NAME="home_dynamic_ips"
DESC_V4="home dynamic IPv4"
DESC_V6="home dynamic IPv6"

# Notifications
NTFY_ENABLED="yes"
NTFY_URL="https://ntfy.example.com/topic-name"
NTFY_TOKEN="NTFY_TOKEN_HERE"

HANDLE_IPV6="no"

# State File
_SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
STATE_FILE="${_SCRIPT_DIR}/.crowdsec_ip.state"

# Retry Settings
MAX_RETRIES=3
BASE_WAIT=5

# --- Helpers ---

# Trap to clean up temp files on exit
_TMP_OUT=$(mktemp) || { echo "Failed to create temp file"; exit 1; }
trap 'rm -f "$_TMP_OUT"' EXIT INT TERM

ntfy_send() {
    _n_title="$1"
    _n_msg="$2"
    [ "$NTFY_ENABLED" = "yes" ] || return 0
    curl -s -X POST \
        -H "Authorization: Bearer $NTFY_TOKEN" \
        -H "Title: $_n_title" \
        -d "$_n_msg" \
        "$NTFY_URL" >/dev/null 2>&1 || :
}

# Exponential Backoff Wrapper
run_with_backoff() {
    _rb_desc="$1"
    shift
    _rb_attempt=1
    while [ "$_rb_attempt" -le "$MAX_RETRIES" ]; do
        if "$@"; then return 0; fi
        _rb_wait=$(( _rb_attempt * BASE_WAIT ))
        if [ "$_rb_attempt" -lt "$MAX_RETRIES" ]; then
            echo "[$_rb_desc] Attempt $_rb_attempt failed. Retrying in ${_rb_wait}s..." >&2
            sleep "$_rb_wait"
        fi
        _rb_attempt=$(( _rb_attempt + 1 ))
    done
    echo "[$_rb_desc] Failed after $MAX_RETRIES attempts." >&2
    return 1
}

# SSH Helper (Centralizes flags)
# shellcheck disable=SC2329
ssh_exec() {
    _SSH_OPT_KEY=""
    if [ -n "$SSH_KEY" ]; then _SSH_OPT_KEY="-i $SSH_KEY"; fi
    # shellcheck disable=SC2086
    ssh -q -o BatchMode=yes -o ConnectTimeout=10 \
        $_SSH_OPT_KEY -p "${SSH_PORT:-22}" "${SSH_USER}@${VPS_HOST}" "$@"
}

# --- IP Detection Logic ---
# shellcheck disable=SC2329
_fetch_ipv4_core() {
    _f_ip=$(curl -4 -s --connect-timeout 5 https://ip.me || curl -4 -s --connect-timeout 5 https://api.ipify.org)
    _f_ip=$(printf '%s\n' "$_f_ip" | tr -d ' \t\r\n')
    case "$_f_ip" in
        *.*.*.*) printf '%s\n' "$_f_ip"; return 0 ;;
        *) return 1 ;;
    esac
}
# shellcheck disable=SC2329
_fetch_ipv6_core() {
    _f_ip=$(curl -6 -s --connect-timeout 5 https://api64.ipify.org || curl -6 -s --connect-timeout 5 https://ip.me)
    _f_ip=$(printf '%s\n' "$_f_ip" | tr -d ' \t\r\n')
    case "$_f_ip" in
        *:*:*) printf '%s\n' "$_f_ip"; return 0 ;;
        *) return 1 ;;
    esac
}
# shellcheck disable=SC2329
fetch_ipv4_to_tmp() { _fetch_ipv4_core > "$_TMP_OUT"; }
# shellcheck disable=SC2329
fetch_ipv6_to_tmp() { _fetch_ipv6_core > "$_TMP_OUT"; }

# --- Remote List Logic (Restored) ---

# Wrapper to fetch the list to temp file
# shellcheck disable=SC2329
fetch_remote_list_to_tmp() {
    ssh_exec "docker exec crowdsec cscli allowlists inspect ${ALLOWLIST_NAME} -o human 2>/dev/null" > "$_TMP_OUT"
}

# Wrapper to remove a specific IP
# shellcheck disable=SC2329
remove_remote_ip() {
    _ip_rem="$1"
    ssh_exec "docker exec crowdsec cscli allowlists remove ${ALLOWLIST_NAME} ${_ip_rem}" >/dev/null 2>&1
}

# Wrapper to add a specific IP
# shellcheck disable=SC2329
add_remote_ip() {
    _ip_add="$1"
    _desc="$2"
    ssh_exec "docker exec crowdsec cscli allowlists add ${ALLOWLIST_NAME} ${_ip_add} -d '${_desc}'"
}

# --- Main Execution ---

# 1. Get Local IPv4
if run_with_backoff "Fetch IPv4" fetch_ipv4_to_tmp; then
    CURRENT_IPv4=$(cat "$_TMP_OUT")
else
    ntfy_send "CrowdSec Updater: Failure" "Could not detect local IPv4."
    exit 1
fi

# 2. Get Local IPv6
CURRENT_IPv6=""
if [ "$HANDLE_IPV6" = "yes" ]; then
    if run_with_backoff "Fetch IPv6" fetch_ipv6_to_tmp; then
        CURRENT_IPv6=$(cat "$_TMP_OUT")
    fi
fi

# 3. Check State File (Early Exit Optimization)
CURRENT_STATE="${CURRENT_IPv4}|${CURRENT_IPv6}"
if [ -f "$STATE_FILE" ]; then
    LAST_STATE=$(cat "$STATE_FILE")
    if [ "$CURRENT_STATE" = "$LAST_STATE" ]; then
        exit 0
    fi
fi

# 4. Fetch Remote IPs (To see if we need to clear anything)
REMOTE_IPS=""
if run_with_backoff "Fetch Remote List" fetch_remote_list_to_tmp; then
    REMOTE_IPS=$(cat "$_TMP_OUT" | grep -E '^[0-9a-fA-F:.]' | awk '{print $1}')
else
    ntfy_send "CrowdSec Updater: Error" "Failed to fetch remote list from VPS."
    exit 1
fi

# 5. Clear Old IPs
if [ -n "$REMOTE_IPS" ]; then
    for OLD_IP in $REMOTE_IPS; do
        run_with_backoff "Remove $OLD_IP" remove_remote_ip "$OLD_IP" || :
    done
fi

# 6. Add New IPs
UPDATED="no"
ADDED_IPS=""

# Add IPv4
if run_with_backoff "Add IPv4" add_remote_ip "$CURRENT_IPv4" "$DESC_V4"; then
    UPDATED="yes"
    ADDED_IPS="$CURRENT_IPv4"
else
    ntfy_send "CrowdSec Updater: Error" "Failed to add IPv4 to VPS."
    exit 1
fi

# Add IPv6
if [ -n "$CURRENT_IPv6" ]; then
    if run_with_backoff "Add IPv6" add_remote_ip "$CURRENT_IPv6" "$DESC_V6"; then
        UPDATED="yes"
        ADDED_IPS="$ADDED_IPS, $CURRENT_IPv6"
    fi
fi

# 7. Finalize
if [ "$UPDATED" = "yes" ]; then
    echo "$CURRENT_STATE" > "$STATE_FILE"
    ntfy_send "CrowdSec IP Updated" "Updated allowlist '${ALLOWLIST_NAME}'. New IP: $ADDED_IPS"
fi

exit 0
