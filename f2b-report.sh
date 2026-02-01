#!/bin/bash

# --- Configuration ---
NTFY_URL="https://ntfy-domain.com"
NTFY_TOPIC="ntfy-topic"
NTFY_TOKEN="tk_token_here"
F2B_DB="/var/lib/fail2ban/fail2ban.sqlite3"

# --- Data Gathering ---

# Total unique bans in the last 7 days (using timeofban)
WEEKLY_BANS=$(sqlite3 $F2B_DB \
"SELECT count(*) FROM bans WHERE timeofban > strftime('%s', 'now', '-7 days');")

# Most active jail in the last 7 days
TOP_JAIL=$(sqlite3 $F2B_DB \
"SELECT jail FROM bans WHERE timeofban > strftime('%s', 'now', '-7 days') GROUP BY jail ORDER BY count(*) DESC LIMIT 1;")

# The single IP with the most bans this week
TOP_IP=$(sqlite3 $F2B_DB \
"SELECT ip FROM bans WHERE timeofban > strftime('%s', 'now', '-7 days') GROUP BY ip ORDER BY count(*) DESC LIMIT 1;")

# --- Message Preparation ---

MESSAGE="🛡️ Fail2Ban Weekly Security Report
--------------------------------
✅ Total IPs Banned: $WEEKLY_BANS
🔥 Most Active Jail: ${TOP_JAIL:-None}
📍 Top Offender: ${TOP_IP:-None}
💻 Host: $(hostname)"

# --- Send Notification ---

curl \
  -H "Authorization: Bearer $NTFY_TOKEN" \
  -H "Title: Weekly Security Summary" \
  -H "Priority: default" \
  -H "Tags: shield, bar_chart" \
  -d "$MESSAGE" \
  "$NTFY_URL/$NTFY_TOPIC"