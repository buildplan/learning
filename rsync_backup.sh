#!/bin/bash

# --- Download script ---
# wget https://raw.githubusercontent.com/buildplan/learning/refs/heads/main/rsync_backup.sh
#
# --- SSH KEY ---
# generate SSH key for root if you haven't already
# sudo su
# ssh-keygen -t ed25519
# copy ssh public key to Hetzner storage box
# ssh-copy-id -p 23 -s u400000-sub4@u400000.your-storagebox.de
# adjust the user name for sub account and server address
#
# --- run cron job as root ---
# sudo apt-get install cron
# sudo crontab -e
# 5 5 * * * /home/user1/scripts/rsync-backup/run_backup.sh
#
# --- Prerequisites ---
# This script requires the following commands to be installed and accessible.
# On Debian/Ubuntu:
# sudo apt-get install -y rsync curl netcat-openbsd gawk coreutils
#
# On CentOS/RHEL/Fedora:
# sudo dnf install -y rsync curl flock nc gawk coreutils
#
# - rsync: For the core file transfer.
# - curl: For sending ntfy notifications.
# - flock: For preventing concurrent script runs.
# - nc (netcat): For the network connectivity check.
# - gawk (awk): For processing rsync stats.
# - coreutils (numfmt, stat, etc.): Standard on most systems.
# 
# --- check backup integrity and integrity summary --
# sudo ./rsync_backup.sh --summary
# sudo ./rsync_backup.sh --checksum
# --- dry-run ---
# sudo ./rsync_backup.sh --dry-run
#
# =================================================================
#               SCRIPT CONFIGURATION & OPTIONS
# =================================================================
# -E: ERR traps are inherited by shell functions.
# -u: Exit on unset variables.
# -o pipefail: Exit status of a pipeline is the rightmost failing command.
# -e: Exit on command errors.
set -Euo pipefail

# Set a secure umask for files created by this script (e.g., logs, locks).
umask 077

# --- Paths to Commands (Found automatically - can also be defined as static with 'which <command>') ---
RSYNC_CMD=$(command -v rsync)
CURL_CMD=$(command -v curl)
FLOCK_CMD=$(command -v flock)
HOSTNAME_CMD=$(command -v hostname)
CUT_CMD=$(command -v cut)
DATE_CMD=$(command -v date)
ECHO_CMD=$(command -v echo)
STAT_CMD=$(command -v stat)
MV_CMD=$(command -v mv)
TOUCH_CMD=$(command -v touch)
NC_CMD=$(command -v nc)
AWK_CMD=$(command -v awk)
NUMFMT_CMD=$(command -v numfmt)
GREP_CMD=$(command -v grep)

# --- Logging, Rotation & Locking ---
LOG_FILE="/var/log/backup_rsync.log"
LOCK_FILE="/tmp/backup_rsync.lock"
MAX_LOG_SIZE=10485760 # 10 MB in bytes

# --- Source and Destination ---
LOCAL_DIR="/home/user1/" # change this
BOX_DIR="/home/vps/" # change this

# --- rsync & SSH ---
EXCLUDE_FROM="/home/user1/scripts/rsync-backup/rsync_exclude.txt" # change this # make sure rsync_exclude.txt exist and path is correct
HETZNER_BOX="u400000-sub4@u400000.your-storagebox.de" # change this
SSH_PORT="23"

# --- ntfy Notifications ---
NTFY_TOKEN="tk_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" # change this
NTFY_URL="https://ntfy.mydomain.com/backups" # change this

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

# --- Function to run the rsync integrity check ---
run_integrity_check() {
    local rsync_output
    rsync_output=$(LC_ALL=C "$RSYNC_CMD" -avz --checksum --dry-run --stats --delete --exclude-from="$EXCLUDE_FROM" -e "ssh -p $SSH_PORT" "$LOCAL_DIR" "$HETZNER_BOX":"$BOX_DIR" 2>&1 | tee -a "$LOG_FILE")

    echo "${rsync_output}" | "$GREP_CMD" -v -E "sending incremental file list|^$|Number of files:|Total file size:|Total transferred file size:|total size is" || true
}

# --- Function to format backup stats ---
format_backup_stats() {
    local stats_line
    stats_line=$("$GREP_CMD" 'Total transferred file size' "$LOG_FILE" | tail -n 1)

    if [ -n "$stats_line" ]; then
        local bytes
        bytes=$(echo "$stats_line" | "$AWK_CMD" '{gsub(/,/, ""); print $5}')

        if [[ "$bytes" =~ ^[0-9]+$ ]] && [[ "$bytes" -gt 0 ]]; then
            local human_readable
            human_readable=$("$NUMFMT_CMD" --to=iec-i --suffix=B --format="%.2f" "$bytes")
            printf "Data Transferred: %s" "${human_readable}"
        else
            printf "Data Transferred: 0 B (No changes)"
        fi
    else
        printf "See log for statistics."
    fi
}

# --- Global ERR Trap ---
trap 'send_ntfy "❌ Backup Crashed: ${HOSTNAME}" "x" "high" "Backup script terminated unexpectedly. Check log: ${LOG_FILE}"' ERR

# --- Automated Prerequisite Check ---
# Verify that all required commands are available before proceeding.
for cmd_path in \
    "$RSYNC_CMD" \
    "$CURL_CMD" \
    "$FLOCK_CMD" \
    "$NC_CMD" \
    "$AWK_CMD" \
    "$NUMFMT_CMD" \
    "$GREP_CMD" \
    "$HOSTNAME_CMD" \
    "$CUT_CMD" \
    "$DATE_CMD" \
    "$STAT_CMD" \
    "$MV_CMD" \
    "$TOUCH_CMD"
do
    # Use 'command -v' to check if the command exists and is executable.
    if ! command -v "$cmd_path" &>/dev/null; then
        # Extract just the command name for the error message
        cmd_name=$(basename "$cmd_path")
        echo "FATAL: Required command '$cmd_name' not found at '$cmd_path'. Please install it." >&2
        # We can't send a notification because curl might be the missing command.
        trap - ERR # Disable trap before our intentional exit.
        exit 10
    fi
done

# --- check SSH connectivity ---
if ! ssh -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=5 "$HETZNER_BOX" 'exit' 2>/dev/null; then
    send_ntfy "❌ SSH FAILED" "x" "high" "Unable to SSH into $HETZNER_BOX"
    trap - ERR
    exit 6
fi

# --- PRE-FLIGHT CHECKS ---
if ! [ -f "$EXCLUDE_FROM" ]; then
    send_ntfy "❌ Backup FAILED: ${HOSTNAME}" "x" "high" "FATAL: Exclude file not found at $EXCLUDE_FROM"
    trap - ERR
    exit 3
fi
if [[ "$LOCAL_DIR" != */ ]]; then
    send_ntfy "❌ Backup FAILED: ${HOSTNAME}" "x" "high" "FATAL: LOCAL_DIR must end with a trailing slash ('/')"
    trap - ERR
    exit 2
fi

# =================================================================
#                         SCRIPT EXECUTION
# =================================================================

HOSTNAME=$("$HOSTNAME_CMD" | "$CUT_CMD" -d'.' -f1)

# Check for a --dry-run argument
if [[ "${1:-}" == "--dry-run" ]]; then
    # --- DRY-RUN MODE ---
    trap - ERR # Disable the crash trap for dry runs.

    "$ECHO_CMD" "============================================================" | tee -a "$LOG_FILE"
    "$ECHO_CMD" "[$("$DATE_CMD" '+%Y-%m-%d %H:%M:%S')] --- DRY RUN MODE ACTIVATED ---" | tee -a "$LOG_FILE"
    "$ECHO_CMD" "============================================================" | tee -a "$LOG_FILE"

    # Execute rsync with the --dry-run flag. Output goes to terminal AND log.
    "$RSYNC_CMD" -avz --dry-run --delete --exclude-from="$EXCLUDE_FROM" -e "ssh -p $SSH_PORT" "$LOCAL_DIR" "$HETZNER_BOX":"$BOX_DIR" | tee -a "$LOG_FILE"

    "$ECHO_CMD" "[$("$DATE_CMD" '+%Y-%m-%d %H:%M:%S')] --- DRY RUN COMPLETED ---" | tee -a "$LOG_FILE"
    exit 0 # Exit cleanly without locking, notifications, or further logging.
fi

# Check for a --checksum argument (Integrity Check Mode with Notifications)
if [[ "${1:-}" == "--checksum" ]]; then
    trap - ERR

    if [ -f "$LOG_FILE" ] && [ "$("$STAT_CMD" -c%s "$LOG_FILE")" -gt "$MAX_LOG_SIZE" ]; then
        "$MV_CMD" "$LOG_FILE" "${LOG_FILE}.$("$DATE_CMD" +%Y%m%d_%H%M%S)"
        "$TOUCH_CMD" "$LOG_FILE"
    fi

    "$ECHO_CMD" "============================================================" >> "$LOG_FILE"
    "$ECHO_CMD" "[$("$DATE_CMD" '+%Y-%m-%d %H:%M:%S')] --- INTEGRITY CHECK MODE ACTIVATED ---" >> "$LOG_FILE"
    "$ECHO_CMD" "============================================================" >> "$LOG_FILE"

    # Call shared function to get the list of discrepancie
    FILE_DISCREPANCIES=$(run_integrity_check)

    if [ -z "$FILE_DISCREPANCIES" ]; then
        # --- INTEGRITY OK ---
        "$ECHO_CMD" "[$("$DATE_CMD" '+%Y-%m-%d %H:%M:%S')] --- INTEGRITY CHECK PASSED ---" >> "$LOG_FILE"
        send_ntfy "✅ Backup Integrity OK: ${HOSTNAME}" "white_check_mark" "default" "Checksum validation completed successfully. No discrepancies found."
    else
        # --- INTEGRITY FAILED ---
        "$ECHO_CMD" "[$("$DATE_CMD" '+%Y-%m-%d %H:%M:%S')] --- INTEGRITY CHECK FAILED ---" >> "$LOG_FILE"
        ISSUE_LIST=$(echo "${FILE_DISCREPANCIES}" | head -n 10)
        printf -v FAILURE_MSG "Backup integrity check FAILED. Discrepancies found between source and backup.\n\nFirst few differing files:\n%s\n\nCheck log for full details." "${ISSUE_LIST}"
        send_ntfy "❌ Backup Integrity FAILED: ${HOSTNAME}" "x" "high" "${FAILURE_MSG}"
    fi

    exit 0
fi

# Check for a --summary argument (Integrity Check Summary Mode)
if [[ "${1:-}" == "--summary" ]]; then
    trap - ERR

    FILE_DISCREPANCIES=$(run_integrity_check)

    # Count the number of lines in the discrepancy list.
    MISMATCH_COUNT=$(echo "${FILE_DISCREPANCIES}" | wc -l)

    # Print the summary report.
    printf "🚨 Total files with checksum mismatches: %d\n" "$MISMATCH_COUNT"

    exit 0
fi

# --- REAL RUN MODE (Proceeds only if not a dry run) ---

# --- LOCKING ---
exec 200>"$LOCK_FILE"
"$FLOCK_CMD" -n 200 || { echo "Another instance is running, exiting."; exit 5; }

# --- BUILT-IN LOG ROTATION ---
if [ -f "$LOG_FILE" ] && [ "$("$STAT_CMD" -c%s "$LOG_FILE")" -gt "$MAX_LOG_SIZE" ]; then
    "$MV_CMD" "$LOG_FILE" "${LOG_FILE}.$("$DATE_CMD" +%Y%m%d_%H%M%S)"
    "$TOUCH_CMD" "$LOG_FILE"
fi

"$ECHO_CMD" "============================================================" >> "$LOG_FILE"
"$ECHO_CMD" "[$("$DATE_CMD" '+%Y-%m-%d %H:%M:%S')] Starting rsync backup for ${HOSTNAME}" >> "$LOG_FILE"

# --- NETWORK CONNECTIVITY CHECK ---
DEST_HOST=$("$ECHO_CMD" "$HETZNER_BOX" | "$CUT_CMD" -d'@' -f2)

if ! "$NC_CMD" -z -w 5 "$DEST_HOST" "$SSH_PORT"; then
    LOG_MSG="FATAL: Cannot reach destination host $DEST_HOST on port $SSH_PORT. Aborting backup."
    "$ECHO_CMD" "[$("$DATE_CMD" '+%Y-%m-%d %H:%M:%S')] $LOG_MSG" >> "$LOG_FILE"
    send_ntfy "❌ Backup FAILED: ${HOSTNAME}" "x" "high" "$LOG_MSG"
    trap - ERR
    exit 4
fi

# --- proceed with the rsync command ---
if LC_ALL=C "$RSYNC_CMD" -avz --stats --delete --partial --timeout=60 --exclude-from="$EXCLUDE_FROM" -e "ssh -p $SSH_PORT" "$LOCAL_DIR" "$HETZNER_BOX":"$BOX_DIR" >> "$LOG_FILE" 2>&1
then
    # --- SUCCESS ---
    trap - ERR

    "$ECHO_CMD" "[$("$DATE_CMD" '+%Y-%m-%d %H:%M:%S')] SUCCESS: rsync completed successfully." >> "$LOG_FILE"

    BACKUP_STATS=$(format_backup_stats)
    printf -v SUCCESS_MSG "rsync backup completed successfully.\n\n%s" "${BACKUP_STATS}"

    send_ntfy "✅ Backup SUCCESS: ${HOSTNAME}" "white_check_mark" "default" "${SUCCESS_MSG}"
else
    # --- FAILURE ---
    trap - ERR

    EXIT_CODE=$?
    "$ECHO_CMD" "[$("$DATE_CMD" '+%Y-%m-%d %H:%M:%S')] FAILED: rsync exited with status code: $EXIT_CODE." >> "$LOG_FILE"
    send_ntfy "❌ Backup FAILED: ${HOSTNAME}" "x" "high" "rsync failed on ${HOSTNAME} with exit code ${EXIT_CODE}. Check log for details: ${LOG_FILE}"
fi

"$ECHO_CMD" "======================= Run Finished =======================" >> "$LOG_FILE"
"$ECHO_CMD" "" >> "$LOG_FILE"
