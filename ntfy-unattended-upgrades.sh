#!/usr/bin/env bash

# 1. Save script to a standard location for system-wide scripts, like /usr/local/bin/.
# 2. Make the Script Executable sudo chmod +x /usr/local/bin/ntfy-unattended-upgrades.sh
# 3. Tell `apt` (which controls `unattended-upgrades`) to run your script using the `Post-Invoke` hook. 
# This hook runs after `apt` operations are complete.
#
# Create a new configuration file in the `apt.conf.d` directory:
# sudo nano /etc/apt/apt.conf.d/99-notify-on-upgrade
# Paste the following lines into this new file:
#
# // Run script after unattended-upgrades
# Unattended-Upgrade::Post-Invoke {
#     // Check if the script exists and is executable, then run it.
#     "if [ -x /usr/local/bin/ntfy-unattended-upgrades ]; then /usr/local/bin/ntfy-unattended-upgrades || true; fi";
# };
#

set -euo pipefail
IFS=$'\n\t'

# --- Configuration ---
NTFY_URL="https://ntfy.mydomain.com"
NTFY_TOPIC="unattended-upgrades"
# Access token (starts with tk_) - generate with: ntfy token add <username>
NTFY_TOKEN="tk_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
LOGFILE="/var/log/unattended-upgrades/unattended-upgrades.log"
PRIORITY="3" # 1=min, 2=low, 3=default, 4=high, 5=max/urgent
# --- End Configuration ---

# Check if the log file exists and is readable
if [[ ! -r "$LOGFILE" ]]; then
    printf "Error: Cannot read log file %s\n" "$LOGFILE" >&2
    exit 1
fi

# --- Message Content ---
MESSAGE_BODY=$(tail -n 15 "$LOGFILE")
SYSTEM_HOSTNAME=$(hostname -f)
TITLE="Unattended Upgrades: $SYSTEM_HOSTNAME"

# Format message with markdown code block for better readability
MESSAGE=$(cat <<EOF
Recent upgrade activity on $SYSTEM_HOSTNAME

\`\`\`
$MESSAGE_BODY
\`\`\`
EOF
)
# --- End Message Content ---

# --- Send Notification ---
HTTP_CODE=$(curl -sf \
    --connect-timeout 15 \
    --max-time 30 \
    -w "%{http_code}" \
    -o /dev/null \
    -H "Authorization: Bearer $NTFY_TOKEN" \
    -H "Title: $TITLE" \
    -H "Priority: $PRIORITY" \
    -H "Tags: package,computer" \
    -d "$MESSAGE" \
    "$NTFY_URL/$NTFY_TOPIC")

if [[ "$HTTP_CODE" -ne 200 ]]; then
    printf "Error: Failed to send notification to ntfy (HTTP %s)\n" "$HTTP_CODE" >&2
    exit 1
fi

# --- End Send Notification ---

printf "Notification sent successfully to %s/%s\n" "$NTFY_URL" "$NTFY_TOPIC"
exit 0
