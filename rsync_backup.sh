#!/bin/bash

# --- run as cron job as root ---
# 5 5 * * * /home/hali/scripts/rsync-backup/run_backup.sh

set -Euo pipefail
umask 077

# --- Paths to Commands (Verify with 'which <command>') ---
RSYNC_CMD="/usr/bin/rsync"
CURL_CMD="/usr/bin/curl"
FLOCK_CMD="/usr/bin/flock"
HOSTNAME_CMD="/usr/bin/hostname"
CUT_CMD="/usr/bin/cut"
DATE_CMD="/usr/bin/date"
ECHO_CMD="/usr/bin/echo"
STAT_CMD="/usr/bin/stat"
MV_CMD="/usr/bin/mv"
TOUCH_CMD="/usr/bin/touch"

# --- Source and Destination ---
LOCAL_DIR="/home/user1/"
BOX_DIR="/home/vps/"

# --- rsync & SSH ---
EXCLUDE_FROM="/home/user1/scripts/rsync-backup/rsync_exclude.txt"
HETZNER_BOX="u400000-sub4@u400000.your-storagebox.de"
SSH_PORT="23"

# --- Logging, Rotation & Locking ---
LOG_FILE="/var/log/backup_rsync.log"
LOCK_FILE="/tmp/backup_rsync.lock"
MAX_LOG_SIZE=10485760 # 10 MB in bytes

# --- ntfy Notifications ---
NTFY_TOKEN="tk_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
NTFY_URL="https://ntfy.mydomain.com/backups"

# --- ntfy function ---
send_ntfy() {
    local title="$1"
    local tags="$2"
    local priority="${3:-default}"
    local message="$4"
    "$CURL_CMD" -s -u :"$NTFY_TOKEN" \
        -H "Title: ${title}" \
        -H "Tags: ${tags}" \
        -H "Priority: ${priority}" \
        -d "$message" \
        "$NTFY_URL" > /dev/null 2>> "$LOG_FILE"
}

# =================================================================

# --- PRE-FLIGHT CHECKS ---
[ -f "$EXCLUDE_FROM" ] || { "$ECHO_CMD" "FATAL: Exclude file not found at $EXCLUDE_FROM"; exit 3; }
[[ "$LOCAL_DIR" == */ ]] || { "$ECHO_CMD" "FATAL: LOCAL_DIR must end with a trailing slash ('/')"; exit 2; }

# --- SCRIPT EXECUTION ---
HOSTNAME=$("$HOSTNAME_CMD" | "$CUT_CMD" -d'.' -f1)

# Check for a --dry-run argument
if [[ "${1:-}" == "--dry-run" ]]; then
    # --- DRY-RUN MODE ---
    "$ECHO_CMD" "============================================================" | tee -a "$LOG_FILE"
    "$ECHO_CMD" "[$("$DATE_CMD" '+%Y-%m-%d %H:%M:%S')] --- DRY RUN MODE ACTIVATED ---" | tee -a "$LOG_FILE"
    "$ECHO_CMD" "============================================================" | tee -a "$LOG_FILE"

    # Execute rsync with the --dry-run flag. Output goes to terminal AND log.
    "$RSYNC_CMD" -avz --dry-run --delete --exclude-from="$EXCLUDE_FROM" -e "ssh -p $SSH_PORT" "$LOCAL_DIR" "$HETZNER_BOX":"$BOX_DIR" | tee -a "$LOG_FILE"

    "$ECHO_CMD" "[$("$DATE_CMD" '+%Y-%m-%d %H:%M:%S')] --- DRY RUN COMPLETED ---" | tee -a "$LOG_FILE"
    exit 0 # Exit cleanly without locking, notifications, or further logging.
fi

# --- REAL RUN MODE (Proceeds only if not a dry run) ---

# --- LOCKING ---
exec 200>"$LOCK_FILE"
"$FLOCK_CMD" -n 200 || exit 1

# --- BUILT-IN LOG ROTATION ---
if [ -f "$LOG_FILE" ] && [ "$("$STAT_CMD" -c%s "$LOG_FILE")" -gt "$MAX_LOG_SIZE" ]; then
    "$MV_CMD" "$LOG_FILE" "${LOG_FILE}.$("$DATE_CMD" +%Y%m%d_%H%M%S)"
    "$TOUCH_CMD" "$LOG_FILE"
fi

"$ECHO_CMD" "============================================================" >> "$LOG_FILE"
"$ECHO_CMD" "[$("$DATE_CMD" '+%Y-%m-%d %H:%M:%S')] Starting rsync backup for ${HOSTNAME}" >> "$LOG_FILE"

# --- NETWORK CONNECTIVITY CHECK ---
DEST_HOST=$("$ECHO_CMD" "$HETZNER_BOX" | "$CUT_CMD" -d'@' -f2)

if ! nc -z -w 5 "$DEST_HOST" "$SSH_PORT"; then
    LOG_MSG="FATAL: Cannot reach destination host $DEST_HOST on port $SSH_PORT. Aborting backup."
    "$ECHO_CMD" "[$("$DATE_CMD" '+%Y-%m-%d %H:%M:%S')] $LOG_MSG" >> "$LOG_FILE"
    send_ntfy "❌ Backup FAILED: ${HOSTNAME}" "x" "high" "$LOG_MSG"
    exit 4 # Exit with a specific code for network failure
fi

# --- proceed with the rsync command ---
if "$RSYNC_CMD" -avz --stats --delete --partial --timeout=60 --exclude-from="$EXCLUDE_FROM" -e "ssh -p $SSH_PORT" "$LOCAL_DIR" "$HETZNER_BOX":"$BOX_DIR" >> "$LOG_FILE" 2>&1
then
    # --- SUCCESS ---
    "$ECHO_CMD" "[$("$DATE_CMD" '+%Y-%m-%d %H:%M:%S')] SUCCESS: rsync completed successfully." >> "$LOG_FILE"

    BACKUP_STATS=$(grep -E 'Number of files transferred|Total file size' "$LOG_FILE" | tail -n 2 || true)

    if [ -z "$BACKUP_STATS" ]; then
        BACKUP_STATS="See log for details."
    fi

    send_ntfy "✅ Backup SUCCESS: ${HOSTNAME}" "white_check_mark" "default" -d $"rsync backup completed successfully.\n\n${BACKUP_STATS}"
else
    # --- FAILURE ---
    EXIT_CODE=$?
    "$ECHO_CMD" "[$("$DATE_CMD" '+%Y-%m-%d %H:%M:%S')] FAILED: rsync exited with status code: $EXIT_CODE." >> "$LOG_FILE"
    send_ntfy "❌ Backup FAILED: ${HOSTNAME}" "x" "high" "rsync failed on ${HOSTNAME} with exit code ${EXIT_CODE}. Check log for details: ${LOG_FILE}"
fi

"$ECHO_CMD" "======================= Run Finished =======================" >> "$LOG_FILE"
"$ECHO_CMD" "" >> "$LOG_FILE"
