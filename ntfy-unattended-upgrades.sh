#!/usr/bin/env bash

# install-ntfy-upgrades.sh
# Installer for ntfy-unattended-upgrades notification system
#
# Quick Install:
#    curl -fsSL https://raw.githubusercontent.com/buildplan/learning/main/ntfy-unattended-upgrades.sh | sudo bash
#
# Or download and review first (recommended):
#    wget https://raw.githubusercontent.com/buildplan/learning/main/ntfy-unattended-upgrades.sh
#    chmod +x install-ntfy-upgrades.sh
#    sudo ./install-ntfy-upgrades.sh
#
# Usage:
#    sudo ./install-ntfy-upgrades.sh              # Normal installation
#    sudo ./install-ntfy-upgrades.sh --dry-run    # Show what would be done
#    sudo ./install-ntfy-upgrades.sh --uninstall  # Remove everything
#
# This script will:
#    1. Check if 'unattended-upgrades' is installed and enabled.
#    2. Install the notification script to /usr/local/bin/
#    3. Create a secure config file at /etc/ntfy-upgrades.conf
#    4. Configure an APT hook to trigger notifications
#    5. Run a test notification

set -euo pipefail
IFS=$'\n\t'

# --- Script Paths ---
SCRIPT_PATH="/usr/local/bin/ntfy-unattended-upgrades"
CONFIG_PATH="/etc/ntfy-upgrades.conf"
HOOK_PATH="/etc/apt/apt.conf.d/99-notify-on-upgrade"
LOG_FILE="/var/log/unattended-upgrades/unattended-upgrades.log"

# --- Variables ---
DRY_RUN=false

# --- Parse Arguments ---
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    printf "Running in DRY-RUN mode. No files will be written.\n\n"
elif [[ "${1:-}" == "--uninstall" ]]; then
    check_root
    uninstall
    exit 0
elif [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
    show_help
    exit 0
fi

# --- Main Logic ---
main() {
    # Step 1: Must be run as root
    check_root

    # Step 2: Check unattended-upgrades status
    check_unattended_upgrades

    # Step 3: Get user configuration
    get_config

    # Step 4: Write all the files
    write_main_script
    write_config_file
    write_apt_hook

    # Step 5: Run a test
    run_test

    printf "\n✅ Success! Installation is complete.\n"
    printf "You will now receive ntfy notifications after unattended-upgrades run.\n"
}

# --- Function Definitions ---

# Show help message
show_help() {
    cat << 'HELPTEXT'
install-ntfy-upgrades.sh - Install ntfy notifications for unattended-upgrades

USAGE:
    sudo ./install-ntfy-upgrades.sh [OPTIONS]

OPTIONS:
    (none)           Normal installation
    --dry-run        Show what would be done without making changes
    --uninstall      Remove all installed files
    --help, -h       Show this help message

DESCRIPTION:
    This script installs a notification system that sends alerts via ntfy
    whenever unattended-upgrades runs on your Debian/Ubuntu server.

EXAMPLES:
    sudo ./install-ntfy-upgrades.sh
    sudo ./install-ntfy-upgrades.sh --dry-run
    sudo ./install-ntfy-upgrades.sh --uninstall
HELPTEXT
}

# Check if running as root
check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        printf "Error: This script must be run as root.\n" >&2
        printf "Please run with: sudo %s\n" "$0" >&2
        exit 1
    fi
}

# Check if unattended-upgrades is installed and enabled
check_unattended_upgrades() {
    printf "\n--- Checking Unattended-Upgrades Status ---\n"
    
    # Check if package is installed
    if ! dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null | grep -q "install ok installed"; then
        printf "⚠️  Package 'unattended-upgrades' is NOT installed.\n"
        
        if [[ "$DRY_RUN" == true ]]; then
            printf "[DRY-RUN] Would prompt to install 'unattended-upgrades'\n"
            return
        fi

        # check apt-get
        if ! command -v apt-get &> /dev/null; then
            printf "Error: apt-get not found. This script requires Debian/Ubuntu.\n" >&2
            exit 1
        fi

        read -rp $'Would you like to install it now? (y/N): ' install_confirm
        if [[ "$install_confirm" =~ ^[Yy]$ ]]; then
            printf "Installing unattended-upgrades...\n"
            apt-get update -qq
            apt-get install -y unattended-upgrades
            printf "✓ Package installed\n"
        else
            printf "\nWarning: Notifications will not work without unattended-upgrades installed.\n"
            read -rp $'Continue anyway? (y/N): ' continue_confirm
            if [[ ! "$continue_confirm" =~ ^[Yy]$ ]]; then
                printf "Installation cancelled.\n"
                exit 0
            fi
            return
        fi
    else
        printf "✓ Package 'unattended-upgrades' is installed\n"
    fi
    
    # Check if it's enabled by looking at the config file
    local config_file="/etc/apt/apt.conf.d/20auto-upgrades"
    local is_enabled=false
    
    if [[ -f "$config_file" ]]; then
        if grep -q 'APT::Periodic::Unattended-Upgrade "1"' "$config_file"; then
            is_enabled=true
            printf "✓ Unattended-upgrades is enabled\n"
        fi
    fi
    
    if [[ "$is_enabled" == false ]]; then
        printf "⚠️  Unattended-upgrades is NOT enabled.\n"

        if [[ "$DRY_RUN" == true ]]; then
            printf "[DRY-RUN] Would prompt to enable 'unattended-upgrades'\n"
            return
        fi

        read -rp $'Would you like to enable it now? (y/N): ' enable_confirm
        if [[ "$enable_confirm" =~ ^[Yy]$ ]]; then
            enable_unattended_upgrades
        else
            printf "\nWarning: Your system will not automatically upgrade without this enabled.\n"
            read -rp $'Continue anyway? (y/N): ' continue_confirm
            if [[ ! "$continue_confirm" =~ ^[Yy]$ ]]; then
                printf "Installation cancelled.\n"
                exit 0
            fi
        fi
    fi
    
    # Check systemd timers (this is a read-only check, safe for dry-run)
    printf "\nChecking systemd timers...\n"
    if systemctl is-active --quiet apt-daily-upgrade.timer; then
        printf "✓ apt-daily-upgrade.timer is active\n"
    else
        printf "⚠️  apt-daily-upgrade.timer is NOT active\n"
    fi
}

# Enable unattended-upgrades non-interactively
enable_unattended_upgrades() {
    printf "Enabling unattended-upgrades...\n"
    
    if [[ "$DRY_RUN" == true ]]; then
        printf "[DRY-RUN] Would write /etc/apt/apt.conf.d/20auto-upgrades\n"
        printf "[DRY-RUN] Would enable systemd timers\n"
        printf "✓ Unattended-upgrades enabled (dry-run)\n"
        return
    fi
    
    # Create the config file non-interactively
    cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF
    
    # Ensure systemd timers are enabled
    systemctl enable apt-daily.timer 2>/dev/null || true
    systemctl enable apt-daily-upgrade.timer 2>/dev/null || true
    
    printf "✓ Unattended-upgrades enabled\n"
}

# Ask for ntfy settings
get_config() {
    printf "\n--- ntfy Configuration ---\n"
    printf "Please enter your ntfy server details.\n\n"

    read -rp "Enter your ntfy server URL (e.g., https://ntfy.mydomain.com): " NTFY_URL
    read -rp "Enter the ntfy topic name (e.g., unattended-upgrades): " NTFY_TOPIC
    read -rsp "Enter your ntfy access token (tk_...): " NTFY_TOKEN
    printf "\n"

    # Validate input
    if [[ -z "$NTFY_URL" ]] || [[ -z "$NTFY_TOPIC" ]] || [[ -z "$NTFY_TOKEN" ]]; then
        printf "\nError: All fields are required. Aborting.\n" >&2
        exit 1
    fi
    
    # Validate URL format
    if [[ ! "$NTFY_URL" =~ ^https?:// ]]; then
        printf "\nError: NTFY_URL must start with http:// or https://\n" >&2
        exit 1
    fi
    
    # Remove trailing slash from URL if present
    NTFY_URL="${NTFY_URL%/}"
    
    # Validate token format
    if [[ ! "$NTFY_TOKEN" =~ ^tk_ ]]; then
        read -rp $'\nWarning: ntfy tokens typically start with \'tk_\'. Continue anyway? (y/N): ' confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            printf "Installation cancelled.\n"
            exit 0
        fi
    fi
    
    # Show configuration and confirm
    printf "\nConfiguration received.\n"
    printf "\nReview your settings:\n"
    printf "  NTFY_URL:   %s\n" "$NTFY_URL"
    printf "  NTFY_TOPIC: %s\n" "$NTFY_TOPIC"
    printf "  NTFY_TOKEN: %s...\n" "${NTFY_TOKEN:0:8}"
    read -rp $'\nProceed with installation? (y/N): ' confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        printf "Installation cancelled.\n"
        exit 0
    fi
}

# Write the main notification script
write_main_script() {
    printf "\nInstalling main script to %s...\n" "$SCRIPT_PATH"
    
    if [[ "$DRY_RUN" == true ]]; then
        printf "[DRY-RUN] Would write script to %s\n" "$SCRIPT_PATH"
        return
    fi
    
    cat << 'MAIN_SCRIPT_EOF' > "$SCRIPT_PATH"
#!/usr/bin/env bash
# ntfy-unattended-upgrades - Send notifications after unattended-upgrades
# This script is automatically installed and managed.

set -euo pipefail
IFS=$'\n\t'

# --- Configuration ---
CONFIG_FILE="/etc/ntfy-upgrades.conf"

if [[ ! -r "$CONFIG_FILE" ]]; then
    printf "Error: Cannot read config file %s\n" "$CONFIG_FILE" >&2
    exit 0 # Exit 0 so we don't break apt
fi

# Load the secret variables
# shellcheck source=/dev/null
source "$CONFIG_FILE"

# --- Script Defaults (can be overridden) ---
LOGFILE="${LOGFILE:-/var/log/unattended-upgrades/unattended-upgrades.log}"
PRIORITY="${PRIORITY:-3}"
# --- End Configuration ---

if [[ ! -r "$LOGFILE" ]]; then
    printf "Warning: Log file %s not found. Sending basic notification.\n" "$LOGFILE" >&2
    MESSAGE_BODY="Log file $LOGFILE not found. This may be normal if upgrades haven't run yet."
else
    MESSAGE_BODY=$(tail -n 15 "$LOGFILE")
fi

# --- Message Content ---
SYSTEM_HOSTNAME=$(hostname -f)
TITLE="Unattended Upgrades: $SYSTEM_HOSTNAME"

MESSAGE=$(cat <<EOM
Recent upgrade activity on $SYSTEM_HOSTNAME

\`\`\`
$MESSAGE_BODY
\`\`\`
EOM
)
# --- End Message Content ---

# --- Send Notification ---
if [[ -z "${NTFY_URL:-}" ]] || [[ -z "${NTFY_TOPIC:-}" ]] || [[ -z "${NTFY_TOKEN:-}" ]]; then
    printf "Error: NTFY_URL, NTFY_TOPIC, or NTFY_TOKEN is not set in %s\n" "$CONFIG_FILE" >&2
    exit 0 # Exit 0 so we don't break apt
fi

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
    exit 0 # Exit 0 so we don't break apt
fi

printf "Notification sent successfully to %s/%s\n" "$NTFY_URL" "$NTFY_TOPIC"
exit 0
MAIN_SCRIPT_EOF

    chmod +x "$SCRIPT_PATH"
    printf "✓ Script installed\n"
}

# Write the secret config file
write_config_file() {
    printf "Writing configuration to %s...\n" "$CONFIG_PATH"
    
    if [[ "$DRY_RUN" == true ]]; then
        printf "[DRY-RUN] Would write config to %s\n" "$CONFIG_PATH"
        return
    fi
    
    cat << EOF > "$CONFIG_PATH"
# ntfy configuration for unattended-upgrades
# This file contains secrets - keep permissions at 600
NTFY_URL="$NTFY_URL"
NTFY_TOPIC="$NTFY_TOPIC"
NTFY_TOKEN="$NTFY_TOKEN"

# Optional: Override notification priority (1=min, 2=low, 3=default, 4=high, 5=max)
# PRIORITY="3"
EOF

    chmod 600 "$CONFIG_PATH"
    chown root:root "$CONFIG_PATH"
    printf "✓ Configuration saved (permissions: 600)\n"
}

# Write the APT hook file
write_apt_hook() {
    printf "Installing APT hook at %s...\n" "$HOOK_PATH"
    
    if [[ "$DRY_RUN" == true ]]; then
        printf "[DRY-RUN] Would write hook to %s\n" "$HOOK_PATH"
        return
    fi
    
    cat << 'APT_HOOK_EOF' > "$HOOK_PATH"
// Run script after unattended-upgrades
Unattended-Upgrade::Post-Invoke {
     // Check if the script exists and is executable, then run it.
     // The "|| true" ensures that a notification failure
     // (e.g., ntfy server is down) does NOT cause apt to fail.
     "if [ -x /usr/local/bin/ntfy-unattended-upgrades ]; then /usr/local/bin/ntfy-unattended-upgrades || true; fi";
};
APT_HOOK_EOF

    printf "✓ APT hook installed\n"
}

# Run a final test
run_test() {
    if [[ "$DRY_RUN" == true ]]; then
        printf "\n[DRY-RUN] Would run test notification\n"
        return
    fi
    
    printf "\n--- Running Test Notification ---\n"
    printf "Attempting to send a test notification...\n"
    
    # Check if the real log file exists
    if [[ ! -r "$LOG_FILE" ]]; then
        printf "Warning: Main log file '%s' not found (this is normal for new systems).\n" "$LOG_FILE"
        printf "Sending a test notification with a custom message.\n"
        
        # Create a temporary log file for the test
        local TEST_LOG="/tmp/ntfy-test-log.$$"
        # Make sure tmp file is cleaned up on exit
        trap 'rm -f $TEST_LOG' EXIT
        
        cat > "$TEST_LOG" << 'TEST_LOG_EOF'
This is a test notification from ntfy-unattended-upgrades.
If you receive this, your setup is successful!

The actual notifications will contain the last 15 lines of:
/var/log/unattended-upgrades/unattended-upgrades.log
TEST_LOG_EOF
        
        # Run the script, but override its LOGFILE variable
        LOGFILE="$TEST_LOG" "$SCRIPT_PATH"
        
        # Clean up the test log
        rm -f "$TEST_LOG"
        trap - EXIT # Clear the trap
    else
        # Log file exists, just run the script normally
        "$SCRIPT_PATH"
    fi
    
    printf "✓ Test complete. Please check your ntfy client.\n"
}

# Uninstall function
uninstall() {
    printf "Uninstalling ntfy-unattended-upgrades...\n\n"
    
    local removed=false
    
    if [[ -f "$SCRIPT_PATH" ]]; then
        rm -f "$SCRIPT_PATH"
        printf "✓ Removed %s\n" "$SCRIPT_PATH"
        removed=true
    fi
    
    if [[ -f "$CONFIG_PATH" ]]; then
        rm -f "$CONFIG_PATH"
        printf "✓ Removed %s\n" "$CONFIG_PATH"
        removed=true
    fi
    
    if [[ -f "$HOOK_PATH" ]]; then
        rm -f "$HOOK_PATH"
        printf "✓ Removed %s\n" "$HOOK_PATH"
        removed=true
    fi
    
    if [[ "$removed" == true ]]; then
        printf "\n✅ Uninstall complete.\n"
    else
        printf "\nℹ️  No installed files found.\n"
    fi
}

# --- Run the main function ---
main
