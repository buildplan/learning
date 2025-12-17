#!/bin/sh

# ==============================================================================
# CROWDSEC DYNAMIC HOME IP UPDATER (IPv4 + IPv6 CIDR)
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
#   */15 * * * * QUIET=yes /path/to/this_script.sh >/dev/null 2>&1
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
DESC_V6="home dynamic IPv6 (CIDR)"

# Notifications
NTFY_ENABLED="yes"
NTFY_URL="https://ntfy.example.com/topic"
NTFY_TOKEN="tk_xxxxxxxxxxxxxxxx"

# Settings
HANDLE_IPV6="yes"

# --- Advanced Config ---

# State File
_SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
STATE_FILE="${_SCRIPT_DIR}/.crowdsec_ip.state"

# Retry Settings
MAX_RETRIES=3
BASE_WAIT=5

# --- Helpers ---

_TMP_OUT=$(mktemp) || { echo "Failed to create temp file" >&2; exit 1; }
trap 'rm -f "$_TMP_OUT"' EXIT INT TERM

ntfy_send() {
  _n_title=$1
  _n_msg=$2

  [ "$NTFY_ENABLED" = "yes" ] || return 0

  if command -v curl >/dev/null 2>&1; then
    curl -s -X POST \
      -H "Authorization: Bearer $NTFY_TOKEN" \
      -H "Title: $_n_title" \
      -d "$_n_msg" \
      "$NTFY_URL" >/dev/null 2>&1 || :
  fi
}

run_with_backoff() {
  _rb_desc=$1
  shift

  _rb_attempt=1
  while [ "$_rb_attempt" -le "$MAX_RETRIES" ]; do
    if "$@"; then
      return 0
    fi

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

# Safe single-quote for remote shell strings: ' -> '\'' (POSIX)
sh_quote() {
  printf "%s" "$1" | sed "s/'/'\\\\''/g; 1s/^/'/; \$s/\$/'/"
}

# shellcheck disable=SC2329
ssh_exec() {
  _cmd=$1
  set -- ssh -q -o BatchMode=yes -o ConnectTimeout=10 -p "${SSH_PORT:-22}"
  if [ -n "$SSH_KEY" ]; then
    set -- "$@" -i "$SSH_KEY"
  fi
  set -- "$@" "${SSH_USER}@${VPS_HOST}" "$_cmd"
  "$@"
}

# --- IP Detection Logic ---

# shellcheck disable=SC2329
_fetch_ipv4_core() {
  _f_ip=$(curl -4 -s --connect-timeout 5 https://ip.me \
    || curl -4 -s --connect-timeout 5 https://api.ipify.org) || return 1
  _f_ip=$(printf '%s\n' "$_f_ip" | tr -d ' \t\r\n')

  case "$_f_ip" in
    *.*.*.*) printf '%s\n' "$_f_ip"; return 0 ;;
    *) return 1 ;;
  esac
}

# shellcheck disable=SC2329
get_default_iface() {
  if command -v ip >/dev/null 2>&1; then
    ip route show default 2>/dev/null | awk '
      { for (i=1; i<=NF; i++) if ($i=="dev") { print $(i+1); exit } }'
    return $?
  fi

  # macOS / BSD fallback
  route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}'
}

# Returns an IPv6 CIDR suitable for allowlisting.
# shellcheck disable=SC2329
_fetch_ipv6_cidr_core() {
  _iface=$(get_default_iface) || return 1
  [ -n "$_iface" ] || return 1

  _addr=""
  _plen=""

  # LINUX DETECTION
  if command -v ip >/dev/null 2>&1; then
    _line=$(ip -6 -o addr show dev "$_iface" scope global 2>/dev/null | awk '
      $0 !~ /temporary/ { print $4; exit }
    ')
    _addr=${_line%/*}
    _plen=${_line#*/}

  # MACOS / BSD DETECTION
  else
    _line=$(
      ifconfig "$_iface" 2>/dev/null | awk '
        $1=="inet6" && $2 !~ /^fe80:/ && $0 !~ /temporary/ {
          for (i=1; i<=NF; i++) if ($i=="prefixlen") { print $2 "/" $(i+1); exit }
        }'
    )
    _addr=${_line%/*}
    _plen=${_line#*/}
  fi

  # VALIDATION - Skip empty, link-local, localhost, ULA
  case "$_addr" in
    ""|fe80:*|::1|fc*|fd*) return 1 ;;
  esac

  # NORMALIZE /64
  if [ "$_plen" = "64" ]; then
    case "$_addr" in
        *::*)
            printf "%s/64\n" "$_addr"
            return 0
            ;;
    esac

    _pfx4=$(printf "%s\n" "$_addr" | awk -F: '{print $1 ":" $2 ":" $3 ":" $4}')
    printf "%s::/64\n" "$_pfx4"
    return 0
  fi

  # Fallback
  printf "%s/%s\n" "$_addr" "${_plen}"
}

# shellcheck disable=SC2329
fetch_ipv4_to_tmp() { _fetch_ipv4_core > "$_TMP_OUT"; }
# shellcheck disable=SC2329
fetch_ipv6_cidr_to_tmp() { _fetch_ipv6_cidr_core > "$_TMP_OUT"; }

# --- Main Execution ---

# 1) IPv4
if run_with_backoff "Fetch IPv4" fetch_ipv4_to_tmp; then
  CURRENT_IPv4=$(cat "$_TMP_OUT")
else
  ntfy_send "CrowdSec Failure" "Could not detect local IPv4."
  exit 1
fi

# 2) IPv6 CIDR (optional)
CURRENT_IPv6_CIDR=""
if [ "$HANDLE_IPV6" = "yes" ]; then
  if run_with_backoff "Fetch IPv6 CIDR" fetch_ipv6_cidr_to_tmp; then
    CURRENT_IPv6_CIDR=$(cat "$_TMP_OUT")
  fi
fi

# 3) State file check
QUIET=${QUIET:-no}
CURRENT_STATE="${CURRENT_IPv4}|${CURRENT_IPv6_CIDR}"

if [ -f "$STATE_FILE" ] && [ "$CURRENT_STATE" = "$(cat "$STATE_FILE")" ]; then
  [ "$QUIET" = "yes" ] || echo "No change ($CURRENT_STATE); skipping SSH update."
  exit 0
fi

# 4) Build remote command (nuke & pave)
_q_list_desc=$(sh_quote "$LIST_DESCRIPTION")
_q_desc_v4=$(sh_quote "$DESC_V4")
_q_desc_v6=$(sh_quote "$DESC_V6")

REMOTE_COMMAND="(docker exec crowdsec cscli allowlists delete ${ALLOWLIST_NAME} >/dev/null 2>&1 || true)"
REMOTE_COMMAND="${REMOTE_COMMAND} && docker exec crowdsec cscli allowlists create ${ALLOWLIST_NAME} -d ${_q_list_desc}"
REMOTE_COMMAND="${REMOTE_COMMAND} && docker exec crowdsec cscli allowlists add ${ALLOWLIST_NAME} ${CURRENT_IPv4} -d ${_q_desc_v4}"

if [ -n "$CURRENT_IPv6_CIDR" ]; then
  REMOTE_COMMAND="${REMOTE_COMMAND} && docker exec crowdsec cscli allowlists add ${ALLOWLIST_NAME} ${CURRENT_IPv6_CIDR} -d ${_q_desc_v6}"
fi

# 5) Execute update
if run_with_backoff "SSH Update" ssh_exec "$REMOTE_COMMAND"; then
  echo "$CURRENT_STATE" > "$STATE_FILE"

  MSG="Updated allowlist '${ALLOWLIST_NAME}'. New IPv4: ${CURRENT_IPv4}"
  if [ -n "$CURRENT_IPv6_CIDR" ]; then
    MSG="${MSG}, IPv6 CIDR: ${CURRENT_IPv6_CIDR}"
  fi

  [ "$QUIET" = "yes" ] || echo "$MSG"
  ntfy_send "CrowdSec Updated" "$MSG"
  exit 0
else
  ntfy_send "CrowdSec Error" "Failed to update VPS after retries."
  exit 1
fi
