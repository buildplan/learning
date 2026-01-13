#!/bin/bash

# CrowdSec Installer & Fail2Ban Migrator
# Description: Installs CrowdSec, detects existing Fail2Ban jails, installs equivalent CrowdSec collections, and offers to remove Fail2Ban.
# OS Support: Debian 12/13, Ubuntu 22.04/24.04

set -euo pipefail

# --- Configuration ---
LOG_FILE="/var/log/crowdsec_install_$(date +%Y%m%d_%H%M%S).log"
CROWDSEC_INSTALL_SCRIPT_URL="https://install.crowdsec.net"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- Helper Functions ---

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

print_info() {
    printf "${CYAN}ℹ %s${NC}\n" "$1" | tee -a "$LOG_FILE"
}

print_success() {
    printf "${GREEN}✓ %s${NC}\n" "$1" | tee -a "$LOG_FILE"
}

print_warning() {
    printf "${YELLOW}⚠ %s${NC}\n" "$1" | tee -a "$LOG_FILE"
}

print_error() {
    printf "${RED}✗ %s${NC}\n" "$1" | tee -a "$LOG_FILE"
}

confirm() {
    local prompt="$1"
    local default="${2:-n}"
    local response

    if [[ $default == "y" ]]; then prompt="$prompt [Y/n]: "; else prompt="$prompt [y/N]: "; fi
    read -rp "$(printf "${CYAN}$prompt${NC}")" response
    response=${response,,} # tolower
    [[ -z $response ]] && response=$default

    if [[ "$response" =~ ^(y|yes)$ ]]; then return 0; else return 1; fi
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root."
        exit 1
    fi
}

# --- Main Logic ---

install_crowdsec() {
    print_info "Checking for CrowdSec..."

    if command -v crowdsec >/dev/null 2>&1; then
        print_success "CrowdSec is already installed."
    else
        print_info "Setting up CrowdSec repository..."
        if ! curl -s $CROWDSEC_INSTALL_SCRIPT_URL | sh >> "$LOG_FILE" 2>&1; then
            print_error "Failed to setup CrowdSec repository. Check internet connection."
            exit 1
        fi

        print_info "Installing CrowdSec Agent..."
        if ! apt-get update -qq || ! apt-get install -y -qq crowdsec >> "$LOG_FILE" 2>&1; then
            print_error "Failed to install CrowdSec package."
            exit 1
        fi
        print_success "CrowdSec Agent installed."
    fi

    # Install Firewall Bouncer (Critical for blocking)
    if ! dpkg -l | grep -q crowdsec-firewall-bouncer-iptables; then
        print_info "Installing Firewall Bouncer (iptables/nftables support)..."
        if apt-get install -y -qq crowdsec-firewall-bouncer-iptables >> "$LOG_FILE" 2>&1; then
            print_success "Firewall Bouncer installed."
        else
            print_warning "Failed to install firewall bouncer. CrowdSec will detect attacks but CANNOT block them yet."
        fi
    else
        print_success "Firewall Bouncer already installed."
    fi
}

analyze_fail2ban() {
    print_info "Checking for existing Fail2Ban installation..."

    if ! command -v fail2ban-client >/dev/null 2>&1; then
        print_info "Fail2Ban not found. Skipping migration."
        return 0
    fi

    if ! systemctl is-active --quiet fail2ban; then
        print_warning "Fail2Ban is installed but not active. Skipping jail analysis."
        return 0
    fi

    print_info "Fail2Ban is active. Analyzing enabled jails..."

    # Get list of active jails
    # Clean output to get just names separated by space
    local JAILS
    JAILS=$(fail2ban-client status | grep "Jail list:" | sed 's/.*Jail list://g' | tr -d ',' | xargs)

    if [[ -z "$JAILS" ]]; then
        print_info "No active Fail2Ban jails found."
        return 0
    fi

    print_info "Found active jails: $JAILS"
    print_info "Attempting to map jails to CrowdSec collections..."

    # Update cscli hub to ensure we find collections
    cscli hub update >> "$LOG_FILE" 2>&1

    for jail in $JAILS; do
        case "$jail" in
            sshd|ssh)
                install_collection "crowdsec/sshd" "SSH"
                ;;
            nginx-http-auth|nginx-botsearch|nginx-badbots|nginx-limit-req)
                install_collection "crowdsec/nginx" "Nginx"
                ;;
            apache|apache-auth|apache-badbots|apache-overflows|apache-noscript)
                install_collection "crowdsec/apache2" "Apache"
                ;;
            mysqld-auth|mysql-auth)
                install_collection "crowdsec/mysql" "MySQL"
                ;;
            wordpress|wp-auth)
                install_collection "crowdsec/wordpress" "WordPress"
                ;;
            dovecot)
                install_collection "crowdsec/dovecot" "Dovecot"
                ;;
            postfix)
                install_collection "crowdsec/postfix" "Postfix"
                ;;
            recidive)
                # Recidive is internal to F2B, CrowdSec handles this natively via scenarios
                print_info "Skipping 'recidive' (CrowdSec handles repeat offenders natively)."
                ;;
            *)
                print_warning "No direct mapping found for jail: '$jail'. Search Hub manually: 'cscli hub list'"
                ;;
        esac
    done

    # Handle UFW specifically (if F2B was monitoring UFW logs)
    if [[ "$JAILS" == *"ufw"* ]] || [ -f /var/log/ufw.log ]; then
        print_info "Detecting UFW usage..."
        configure_ufw_acquisition
    fi

    printf "\n"
    print_warning "CrowdSec configured based on your Fail2Ban jails."
    print_warning "Running both Fail2Ban and CrowdSec simultaneously adds redundancy but consumes more resources."

    if confirm "Do you want to stop and disable Fail2Ban now?" "y"; then
        print_info "Stopping Fail2Ban..."
        systemctl stop fail2ban
        systemctl disable fail2ban
        print_success "Fail2Ban stopped and disabled."

        if confirm "Do you want to completely remove Fail2Ban?" "n"; then
            apt-get remove --purge -y fail2ban >> "$LOG_FILE" 2>&1
            print_success "Fail2Ban removed."
        fi
    else
        print_info "Fail2Ban left active. Please ensure they don't conflict (e.g. banning the same IP twice)."
    fi
}

install_collection() {
    local collection="$1"
    local friendly_name="$2"

    if cscli collections list -o json | grep -q "$collection"; then
        print_info "Collection $collection ($friendly_name) already installed."
    else
        print_info "Installing $friendly_name collection ($collection)..."
        if cscli collections install "$collection" >> "$LOG_FILE" 2>&1; then
            print_success "Installed $collection."
        else
            print_error "Failed to install $collection."
        fi
    fi
}

configure_ufw_acquisition() {
    local ACQUIS_FILE="/etc/crowdsec/acquis.d/ufw.yaml"
    mkdir -p /etc/crowdsec/acquis.d

    if [[ -f "$ACQUIS_FILE" ]]; then
        print_info "UFW acquisition configuration already exists."
        return
    fi

    # Check if log exists
    if [[ ! -f /var/log/ufw.log ]]; then
        # Check syslog for UFW entries if separate log doesn't exist
        if grep -q "UFW BLOCK" /var/log/syslog 2>/dev/null; then
            print_info "UFW logs found in syslog. CrowdSec should auto-detect syslog."
            return
        else
            print_warning "/var/log/ufw.log not found. Enabling logging..."
            ufw logging on >> "$LOG_FILE" 2>&1 || true
            touch /var/log/ufw.log
        fi
    fi

    print_info "Configuring CrowdSec to monitor /var/log/ufw.log..."
    cat <<EOF > "$ACQUIS_FILE"
filenames:
  - /var/log/ufw.log
labels:
  type: syslog
EOF
    # Reload needed to pick up new acquisition
    systemctl reload crowdsec
    print_success "UFW log acquisition configured."
}

enroll_console() {
    printf "\n"
    print_info "CrowdSec Console (https://app.crowdsec.net) allows you to visualize alerts and manage bans."
    if confirm "Do you want to enroll this instance in the CrowdSec Console?" "n"; then
        local KEY
        read -rp "$(printf "${CYAN}Enter your Enrollment Key: ${NC}")" KEY
        if [[ -n "$KEY" ]]; then
            print_info "Enrolling..."
            if cscli console enroll "$KEY" >> "$LOG_FILE" 2>&1; then
                print_success "Instance enrolled successfully!"
            else
                print_error "Enrollment failed. Check the key."
            fi
        else
            print_error "No key entered. Skipping."
        fi
    fi
}

verify_installation() {
    print_info "Verifying services..."

    if systemctl is-active --quiet crowdsec; then
        print_success "CrowdSec Agent is active."
    else
        print_error "CrowdSec Agent failed to start. Check 'journalctl -u crowdsec'."
    fi

    if systemctl is-active --quiet crowdsec-firewall-bouncer; then
        print_success "Firewall Bouncer is active."
    elif dpkg -l | grep -q crowdsec-firewall-bouncer-iptables; then
        # Sometimes the service name varies slightly or it failed
        print_warning "Firewall Bouncer service issue. Check 'systemctl status crowdsec-firewall-bouncer'."
    fi

    echo ""
    print_info "Listing installed collections:"
    cscli collections list

    echo ""
    print_info "Listing active bouncers:"
    cscli bouncers list
}

# --- Execution ---

check_root
print_info "Starting CrowdSec Setup & Fail2Ban Migration..."
log "Started script."

install_crowdsec
analyze_fail2ban
systemctl restart crowdsec
enroll_console
verify_installation

printf "\n"
print_success "Setup complete!"
print_info "View logs at: $LOG_FILE"
