##############################################################################################
# save this in /usr/local/sbin/backup_home_to_hetzner.sh                                     #
# copy roor ssh key to Hetzner                                                               #   
# set correct permissions for ssh key with                                                   #
# chmod 600 /root/.ssh/id_ed25519                                                            #
# chmod 700 /root/.ssh                                                                       #
# test:                                                                                      #
# ssh -p 23 u444300-sub4@u444300.your-storagebox.de 'echo "Root SSH key login successful"'   #
##############################################################################################
#!/bin/bash
set -euo pipefail # Exit on error, undefined variable, or pipe failure

# --- Script Configuration ---
LOG_FILE="/var/log/hetzner_home_backup.log" # Log file for this specific script
REMOTE_USER="u444300-sub4"                  # user id Hetzner storage box
REMOTE_HOST="u4444300.your-storagebox.de"
SOURCE_PATH="/home/user/"                # Source: entire /home/n2ali/ directory
REMOTE_DEST_PATH="/home/user/"           # Destination: root of this path on storage box
SSH_PORT="23"
SSH_KEY_PATH="/root/.ssh/id_ed25519"       # Root's private key - script runs as root because of permission isses 

# --- NTFY Configuration ---
NTFY_SERVER_URL="https://ntfy.mydomain.tld"
NTFY_TOPIC="my_registry" # You can change this topic if you want a specific one for backups
NTFY_ACCESS_TOKEN="YOUR_ACTUAL_NTFY_ACCESS_TOKEN_HERE" # <<< IMPORTANT: REPLACE THIS!
# --- End NTFY Configuration ---

# Ensure log file exists and has secure permissions (script runs as root)
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
# Simple log rotation (keeps last 5 logs)
mv "${LOG_FILE}.4" "${LOG_FILE}.5" 2>/dev/null || true
mv "${LOG_FILE}.3" "${LOG_FILE}.4" 2>/dev/null || true
mv "${LOG_FILE}.2" "${LOG_FILE}.3" 2>/dev/null || true
mv "${LOG_FILE}.1" "${LOG_FILE}.2" 2>/dev/null || true
mv "${LOG_FILE}" "${LOG_FILE}.1" 2>/dev/null || true
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

# --- Logging Function ---
log_message() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# --- NTFY Notification Function ---
# Usage: send_ntfy "priority" "Title" "Message" "Optional_Comma_Separated_Tags"
send_ntfy() {
    local ntfy_priority="$1"
    local ntfy_title="$2"
    local ntfy_message="$3"
    local ntfy_tags_csv="$4"

    if [ -z "$NTFY_ACCESS_TOKEN" ] || [ "$NTFY_ACCESS_TOKEN" == "YOUR_ACTUAL_NTFY_ACCESS_TOKEN_HERE" ]; then
        log_message "WARNING: NTFY_ACCESS_TOKEN is not set or is default placeholder. Skipping ntfy notification."
        return
    fi
    if ! command -v curl &> /dev/null; then
        log_message "ERROR: curl command not found. Cannot send ntfy notification."
        return
    fi

    local ntfy_full_url="${NTFY_SERVER_URL}/${NTFY_TOPIC}"
    local curl_cmd=(curl -sS -X POST -H "Authorization: Bearer $NTFY_ACCESS_TOKEN" -H "Title: $ntfy_title" -H "Priority: $ntfy_priority")

    if [ -n "$ntfy_tags_csv" ]; then
        IFS=',' read -ra TAG_ARRAY <<< "$ntfy_tags_csv"
        for tag in "${TAG_ARRAY[@]}"; do
            trimmed_tag=$(echo "$tag" | xargs) 
            if [ -n "$trimmed_tag" ]; then
                curl_cmd+=(-H "Tags: $trimmed_tag")
            fi
        done
    fi
    curl_cmd+=(-d "$ntfy_message" "$ntfy_full_url")

    log_message "Attempting to send ntfy notification: Title='$ntfy_title', Priority='$ntfy_priority', Tags='$ntfy_tags_csv'"
    if output=$("${curl_cmd[@]}" 2>&1); then # Capture output from curl
        log_message "Ntfy notification sent successfully. Response (if any): $output"
    else
        curl_exit_code=$?
        log_message "ERROR: Failed to send ntfy notification. Curl exit code: $curl_exit_code. Curl output: $output"
    fi
}
# --- End NTFY Notification Function ---

# --- Main Backup Logic ---
log_message "===== Starting Hetzner backup run for ${SOURCE_PATH} ====="
send_ntfy "default" "Backup Started: ${SOURCE_PATH} to Hetzner" "Automated backup process for ${SOURCE_PATH} has commenced on n2VPS." "hourglass_flowing_sand"

# rsync options:
# -a: archive mode
# -v: verbose (shows files being transferred; good for logs, can be removed if too noisy for cron)
# -z: compress file data during transfer
# --delete: delete extraneous files from dest dirs
# --partial: keep partially transferred files (replaces --progress from -P, which is better for scripts)
# --checksum for more robust checking, can be removed if performance is an issue.
EXCLUDES=(
    --exclude '.ssh/'      # Excludes /home/n2ali/.ssh/
    --exclude '.docker/'   # Excludes /home/n2ali/.docker/
    # Add any other top-level directories in /home/n2ali you absolutely want to skip. Example:
    # --exclude 'Downloads/'
    # --exclude 'Videos/'
    # --exclude 'snap/' # If /home/n2ali/snap exists and is large
)

log_message "Starting rsync of ${SOURCE_PATH} to ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DEST_PATH}"
# Running rsync. Output will go to the log file.
if rsync -avz --delete --partial --checksum \
    "${EXCLUDES[@]}" \
    -e "ssh -p $SSH_PORT -i $SSH_KEY_PATH" \
    "${SOURCE_PATH}" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DEST_PATH}" >> "$LOG_FILE" 2>&1; then
    
    log_message "Rsync of ${SOURCE_PATH} completed successfully."
    send_ntfy "default" "Backup SUCCESS: ${SOURCE_PATH} to Hetzner" "Automated backup for ${SOURCE_PATH} on n2VPS completed successfully." "white_check_mark,rocket"
else
    rsync_exit_code=$?
    error_message="ERROR: Rsync of ${SOURCE_PATH} failed with exit code ${rsync_exit_code}."
    log_message "$error_message"
    # Try to get the last few lines of rsync error output for the notification
    tail_log=$(tail -n 10 "$LOG_FILE" | grep -Ei 'rsync:|error|denied|failed')
    send_ntfy "urgent" "Backup FAILED: ${SOURCE_PATH} to Hetzner" "$(echo -e "$error_message\nRecent log entries:\n$tail_log\nCheck $LOG_FILE on n2VPS for full logs.")" "x,siren"
fi

log_message "===== Hetzner backup run for ${SOURCE_PATH} finished ====="
echo "" >> "$LOG_FILE" # Add a blank line for readability between runs

exit 0
