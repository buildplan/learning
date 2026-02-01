#!/bin/bash

# --- Configuration ---
NTFY_URL="https://ntfy-domain.com"
NTFY_TOPIC="ntfy-topic"
NTFY_TOKEN="tk_token_here"
F2B_DB="/var/lib/fail2ban/fail2ban.sqlite3"

# --- Data Gathering ---

# Total unique bans (last 7 days)
WEEKLY_BANS=$(sqlite3 $F2B_DB \
"SELECT count(*) FROM bans WHERE timeofban > strftime('%s', 'now', '-7 days');")

# Per-Jail Totals (last 7 days)
JAIL_STATS=$(sqlite3 $F2B_DB \
"SELECT jail || ': ' || count(*) FROM bans WHERE timeofban > strftime('%s', 'now', '-7 days') GROUP BY jail ORDER BY count(*) DESC;")

# Single IP with the most bans this week
TOP_IP=$(sqlite3 $F2B_DB \
"SELECT ip FROM bans WHERE timeofban > strftime('%s', 'now', '-7 days') GROUP BY ip ORDER BY count(*) DESC LIMIT 1;")

# --- Message Preparation ---

MESSAGE="🛡️ Fail2Ban Weekly Security Report
--------------------------------
✅ Total IPs Banned: $WEEKLY_BANS
📍 Top Offender: ${TOP_IP:-None}

📊 Breakdown by Jail:
${JAIL_STATS:-No activity this week}

💻 Host: $(hostname)"

# --- Send Notification ---

curl \
  -H "Authorization: Bearer $NTFY_TOKEN" \
  -H "Title: Weekly Security Summary" \
  -H "Priority: default" \
  -H "Tags: shield, bar_chart" \
  -d "$MESSAGE" \
  "$NTFY_URL/$NTFY_TOPIC"