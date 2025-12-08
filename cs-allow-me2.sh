#!/bin/sh

# ==============================================================================
# CROWDSEC DYNAMIC HOME IP UPDATER
# ==============================================================================
#
# PURPOSE:
#   Detects local public IP and adds it to a CrowdSec allowlist on a remote VPS.
#   Uses a "Nuke & Pave" strategy: deletes the list and recreates it to ensure
#   no stale IPs remain.
#
# FEATURES:
#   - POSIX compliant (runs on Linux & macOS)
#   - State file optimization (skips SSH if IP hasn't changed)
#   - Exponential backoff (retries network failures)
#   - ntfy notifications
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
VPS_HOST="VPS_IP_OR_HOSTNAME"  # Hostname from SSH config or IP
SSH_USER="admin"               # User on CrowdSec host
SSH_PORT="22"                  # Change for custom SSH port
SSH_KEY=""                     # Leave empty or path to key

# CrowdSec Allowlist Details
ALLOWLIST_NAME="home_dynamic_ips"
LIST_DESCRIPTION="Auto-created home IP list"
DESC_V4="home dynamic IPv4"
DESC_V6="home dynamic IPv6"

# Notifications
NTFY_ENABLED="yes"
NTFY_URL="https://ntfy.example.com/topic"
NTFY_TOKEN="YOUR_TOKEN"

# Settings
HANDLE_IPV6="no"

# --- Advanced Config ---

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
    if command -v curl >/dev/null 2>&1; then
        curl -s -X POST \
            -H "Authorization: Bearer $NTFY_TOKEN" \
            -H "Title: $_n_title" \
            -d "$_n_msg" \
            "$NTFY_URL" >/dev/null 2>&1 || :
    fi
}

# Exponential Backoff Wrapper
run_with_backoff() {
    _rb_desc="$1"
    shift
    _rb_attempt=1

    while [ "$_rb_attempt" -le "$MAX_RETRIES" ]; do
        if "$@"; then
            return 0
        fi

        _rb_wait=$(( _rb_attempt * BASE_WAIT ))

        # Only sleep if we have retries left
        if [ "$_rb_attempt" -lt "$MAX_RETRIES" ]; then
            echo "[$_rb_desc] Attempt $_rb_attempt failed. Retrying in ${_rb_wait}s..." >&2
            sleep "$_rb_wait"
        fi
        _rb_attempt=$(( _rb_attempt + 1 ))
    done

    echo "[$_rb_desc] Failed after $MAX_RETRIES attempts." >&2
    return 1
}

# SSH Helper (Safe handling of flags and spaces)
ssh_exec() {
    _SSH_OPT_KEY=""
    if [ -n "$SSH_KEY" ]; then _SSH_OPT_KEY="-i $SSH_KEY"; fi

    # shellcheck disable=SC2086
    ssh -q -o BatchMode=yes -o ConnectTimeout=10 \
        $_SSH_OPT_KEY -p "${SSH_PORT:-22}" "${SSH_USER}@${VPS_HOST}" "$@"
}

# --- IP Detection Logic ---

_fetch_ipv4_core() {
    _f_ip=$(curl -4 -s --connect-timeout 5 https://ip.me || curl -4 -s --connect-timeout 5 https://api.ipify.org)
    _f_ip=$(printf '%s\n' "$_f_ip" | tr -d ' \t\r\n')
    case "$_f_ip" in
        *.*.*.*) printf '%s\n' "$_f_ip"; return 0 ;;
        *) return 1 ;;
    esac
}

_fetch_ipv6_core() {
    _f_ip=$(curl -6 -s --connect-timeout 5 https://api64.ipify.org || curl -6 -s --connect-timeout 5 https://ip.me)
    _f_ip=$(printf '%s\n' "$_f_ip" | tr -d ' \t\r\n')
    case "$_f_ip" in
        *:*:*) printf '%s\n' "$_f_ip"; return 0 ;;
        *) return 1 ;;
    esac
}

fetch_ipv4_to_tmp() { _fetch_ipv4_core > "$_TMP_OUT"; }
fetch_ipv6_to_tmp() { _fetch_ipv6_core > "$_TMP_OUT"; }

# --- Main Execution ---

# 1. Get IPv4 (With Backoff)
if run_with_backoff "Fetch IPv4" fetch_ipv4_to_tmp; then
    CURRENT_IPv4=$(cat "$_TMP_OUT")
else
    ntfy_send "CrowdSec Failure" "Could not detect local IPv4."
    exit 1
fi

# 2. Get IPv6 (Optional)
CURRENT_IPv6=""
if [ "$HANDLE_IPV6" = "yes" ]; then
    if run_with_backoff "Fetch IPv6" fetch_ipv6_to_tmp; then
        CURRENT_IPv6=$(cat "$_TMP_OUT")
    fi
fi

# 3. Check State File
CURRENT_STATE="${CURRENT_IPv4}|${CURRENT_IPv6}"

if [ -f "$STATE_FILE" ]; then
    LAST_STATE=$(cat "$STATE_FILE")
    if [ "$CURRENT_STATE" = "$LAST_STATE" ]; then
        exit 0
    fi
fi

# 4. Prepare Remote Command String
# Strategy: Delete (ignore failure if missing) -> Create -> Add IPs
REMOTE_COMMAND="(docker exec crowdsec cscli allowlists delete ${ALLOWLIST_NAME} >/dev/null 2>&1 || true)"
REMOTE_COMMAND="${REMOTE_COMMAND} && docker exec crowdsec cscli allowlists create ${ALLOWLIST_NAME} -d '${LIST_DESCRIPTION}'"
REMOTE_COMMAND="${REMOTE_COMMAND} && docker exec crowdsec cscli allowlists add ${ALLOWLIST_NAME} ${CURRENT_IPv4} -d '${DESC_V4}'"

if [ -n "$CURRENT_IPv6" ]; then
    REMOTE_COMMAND="${REMOTE_COMMAND} && docker exec crowdsec cscli allowlists add ${ALLOWLIST_NAME} ${CURRENT_IPv6} -d '${DESC_V6}'"
fi

# 5. Execute Update
if run_with_backoff "SSH Update" ssh_exec "$REMOTE_COMMAND"; then
    echo "$CURRENT_STATE" > "$STATE_FILE"

    MSG="Updated allowlist '${ALLOWLIST_NAME}'. New IP: $CURRENT_IPv4"
    if [ -n "$CURRENT_IPv6" ]; then MSG="$MSG, $CURRENT_IPv6"; fi

    ntfy_send "CrowdSec Updated" "$MSG"
    exit 0
else
    ntfy_send "CrowdSec Error" "Failed to update VPS after retries."
    exit 1
fi
