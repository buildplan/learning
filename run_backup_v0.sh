#!/bin/bash
# =================================================================
#                         CONFIGURATION
# =================================================================
# --- Source and Destination ---
LOCAL_DIR="/path/to/local/dir/"
BOX_DIR="/home/backup/dir/path/"

# --- rsync & SSH ---
EXCLUDE_FROM="/path/to/rsync_exclude.txt"
HETZNER_BOX="uxxxxxx-sub4@uxxxxxx.your-storagebox.de"
SSH_PORT="23"

# --- Logging & Locking ---
LOG_FILE="/var/log/backup_rsync.log"
LOCK_FILE="/var/lock/backup_rsync.lock"

# --- ntfy Notifications ---
NTFY_TOKEN="tk_xxxxxxxxxxxxxxxxxxxxxxxxxx"
NTFY_URL="https://ntfy.mydomain.com/backups"
# =================================================================

# --- LOCKING: Exit if lock file is held by another process ---
exec 200>"$LOCK_FILE"
flock -n 200 || exit 1

# Get the hostname of the current server
HOSTNAME=$(hostname | cut -d'.' -f1)

# --- SCRIPT EXECUTION ---

# Add a timestamped header to the log for this run
echo "============================================================" >> "$LOG_FILE"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting rsync backup for ${HOSTNAME}" >> "$LOG_FILE"
echo "============================================================" >> "$LOG_FILE"

# Perform the rsync backup, redirecting its verbose output to the log
rsync -avz --delete --exclude-from="$EXCLUDE_FROM" -e "ssh -p $SSH_PORT" "$LOCAL_DIR" "$HETZNER_BOX":"$BOX_DIR" >> "$LOG_FILE" 2>&1
RSYNC_STATUS=$? # Capture rsync exit code immediately

# Check if rsync was successful and log the final status
if [ $RSYNC_STATUS -eq 0 ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: rsync completed with status $RSYNC_STATUS." >> "$LOG_FILE"
    # --- Success Notification ---
    /usr/bin/curl -u :"$NTFY_TOKEN" \
    -H "Title: ✅ Backup SUCCESS: ${HOSTNAME}" \
    -H "Tags: white_check_mark" \
    -d "rsync completed successfully from ${HOSTNAME}" \
    "$NTFY_URL" > /dev/null 2>&1
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] FAILED: rsync completed with status $RSYNC_STATUS." >> "$LOG_FILE"
    # --- Failure Notification ---
    /usr/bin/curl -u :"$NTFY_TOKEN" \
    -H "Title: ❌ Backup FAILED: ${HOSTNAME}" \
    -H "Tags: x" \
    -H "Priority: high" \
    -d "rsync failed on ${HOSTNAME}. Check log for details: ${LOG_FILE}" \
    "$NTFY_URL" > /dev/null 2>&1
fi

echo "======================= Run Finished =======================" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

# The lock file is released automatically when the script exits.
