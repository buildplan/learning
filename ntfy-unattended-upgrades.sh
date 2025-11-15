#!/usr/bin/env bash

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
