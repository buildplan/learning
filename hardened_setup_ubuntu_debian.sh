#!/bin/bash

# Debian 12 and Ubuntu Server Hardening Interactive Script
# Version: 2.7
# Compatible with: Debian 12 (Bookworm), Ubuntu 20.04 LTS, 22.04 LTS, 24.04 LTS
#
# Description:
# This script provisions and hardens a fresh Debian 12 or Ubuntu server with essential security
# configurations, user management, SSH hardening, firewall setup, and optional features
# like Docker and Tailscale. It is designed to be idempotent, safe, and suitable for
# production environments.
#
# Prerequisites:
# - Run as root on a fresh Debian 12 or Ubuntu server (e.g., sudo ./harden_debian_ubuntu.sh).
# - Internet connectivity is required for package installation.
#
# Usage:
#   sudo ./harden_debian_ubuntu.sh [--quiet]
#
# Options:
#   --quiet: Suppress non-critical output for automation.
#
# Notes:
# - The script creates a log file in /var/log/debian_ubuntu_hardening_*.log.
# - Critical configurations are backed up before modification.
# - A reboot is recommended at the end to apply all changes.
# - Test the script in a VM before production use.
#
# Troubleshooting:
# - Check the log file for errors if the script fails.
# - If SSH access is lost, use the server console to restore /etc/ssh/sshd_config.backup_*.
# - Ensure sufficient disk space (>2GB) for swap file creation.

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Global variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/debian_ubuntu_hardening_$(date +%Y%m%d_%H%M%S).log"
VERBOSE=true
BACKUP_DIR="/root/hardening_backups_$(date +%Y%m%d_%H%M%S)"
IS_CONTAINER=false
SSHD_BACKUP_FILE=""  # Store SSH config backup filename

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --quiet) VERBOSE=false; shift ;;
        *) shift ;;
    esac
done

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Print functions
print_header() {
    [[ $VERBOSE == false ]] && return
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                                                              ║${NC}"
    echo -e "${CYAN}║            DEBIAN/UBUNTU SERVER HARDENING SCRIPT             ║${NC}"
    echo -e "${CYAN}║                                                              ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo
}

print_section() {
    [[ $VERBOSE == false ]] && return
    echo -e "\n${BLUE}▓▓▓ $1 ▓▓▓${NC}" | tee -a "$LOG_FILE"
    echo -e "${BLUE}$(printf '═%.0s' {1..60})${NC}"
}

print_success() {
    [[ $VERBOSE == false ]] && return
    echo -e "${GREEN}✓ $1${NC}" | tee -a "$LOG_FILE"
}

print_warning() {
    [[ $VERBOSE == false ]] && return
    echo -e "${YELLOW}⚠ $1${NC}" | tee -a "$LOG_FILE"
}

print_error() {
    echo -e "${RED}✗ $1${NC}" | tee -a "$LOG_FILE"
}

print_info() {
    [[ $VERBOSE == false ]] && return
    echo -e "${PURPLE}ℹ $1${NC}" | tee -a "$LOG_FILE"
}

# Confirmation function for user prompts
confirm() {
    local prompt="$1"
    local default="${2:-n}"
    local response

    [[ $VERBOSE == false ]] && return 0  # Auto-confirm in quiet mode

    if [[ $default == "y" ]]; then
        prompt="$prompt [Y/n]: "
    else
        prompt="$prompt [y/N]: "
    fi

    while true; do
        read -rp "$(echo -e "${CYAN}$prompt${NC}")" response
        response=${response,,} # Convert to lowercase

        if [[ -z $response ]]; then
            response=$default
        fi

        case $response in
            y|yes) return 0 ;;
            n|no) return 1 ;;
            *) echo -e "${RED}Please answer yes or no.${NC}" ;;
        esac
    done
}

# --- Input Validation Functions ---
validate_username() {
    local username="$1"
    if [[ ! $username =~ ^[a-z_][a-z0-9_-]*$ ]] || [[ ${#username} -gt 32 ]]; then
        return 1
    fi
    return 0
}

validate_hostname() {
    local hostname="$1"
    if [[ $hostname =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]{0,253}[a-zA-Z0-9]$ ]] && [[ ! $hostname =~ \.\. ]]; then
        return 0
    fi
    return 1
}

validate_port() {
    local port="$1"
    if [[ ! $port =~ ^[0-9]+$ ]] || [[ $port -lt 1024 ]] || [[ $port -gt 65535 ]]; then
        return 1
    fi
    return 0
}

# --- Dependency Check and Installation ---
check_dependencies() {
    print_section "Checking Dependencies"

    local missing_deps=()
    command -v curl >/dev/null || missing_deps+=("curl")
    command -v sudo >/dev/null || missing_deps+=("sudo")

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        print_info "Installing missing dependencies: ${missing_deps[*]}"
        if ! apt-get update -qq; then
            print_error "Failed to update package lists."
            exit 1
        fi
        if ! apt-get install -y -qq "${missing_deps[@]}"; then
            print_error "Failed to install dependencies: ${missing_deps[*]}"
            exit 1
        fi
        print_success "Dependencies installed: ${missing_deps[*]}"
    else
        print_success "All dependencies (curl, sudo) are installed."
    fi

    log "Dependency check completed."
}

# --- Core Script Functions ---

check_system() {
    print_section "System Compatibility Check"

    # Enhanced root check
    if [[ $(whoami) != "root" ]]; then
        print_error "This script must be run as root (e.g., sudo ./harden_debian_ubuntu.sh)."
        exit 1
    fi
    print_success "Running with root privileges."

    # Check for container environment
    if [[ -f /proc/1/cgroup ]] && grep -qE '(docker|lxc|kubepod)' /proc/1/cgroup; then
        IS_CONTAINER=true
        print_warning "Container environment detected. Some features (like swap) will be skipped."
    fi

    # Check OS and version
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        if [[ $ID == "debian" && $VERSION_ID == "12" ]] || \
           [[ $ID == "ubuntu" && $VERSION_ID =~ ^(20.04|22.04|24.04)$ ]]; then
            print_success "Compatible OS detected: $PRETTY_NAME"
        else
            print_warning "This script is designed for Debian 12 or Ubuntu 20.04/22.04/24.04 LTS. Detected: $PRETTY_NAME"
            if ! confirm "Continue anyway?"; then
                exit 1
            fi
        fi
    else
        print_error "This doesn't appear to be a Debian or Ubuntu system."
        exit 1
    fi

    # Enhanced internet connectivity check
    if curl -s --head https://deb.debian.org >/dev/null || curl -s --head https://archive.ubuntu.com >/dev/null; then
        print_success "Internet connectivity confirmed."
    else
        print_error "No internet connectivity. Please check your network."
        exit 1
    fi

    # Create log directory
    if [[ ! -w /var/log ]]; then
        print_error "Failed to write to /var/log. Cannot create log file."
        exit 1
    fi

    log "System compatibility check completed successfully."
}

collect_config() {
    print_section "Configuration Setup"

    while true; do
        read -rp "$(echo -e "${CYAN}Enter username for new admin user: ${NC}")" USERNAME
        if validate_username "$USERNAME"; then
            if id "$USERNAME" &>/dev/null; then
                print_warning "User '$USERNAME' already exists."
                if confirm "Use this existing user?"; then
                    USER_EXISTS=true
                    break
                fi
            else
                USER_EXISTS=false
                break
            fi
        else
            print_error "Invalid username. Use lowercase letters, numbers, hyphens, underscores (max 32 chars)."
        fi
    done

    while true; do
        read -rp "$(echo -e "${CYAN}Enter server hostname: ${NC}")" SERVER_NAME
        if validate_hostname "$SERVER_NAME"; then
            break
        else
            print_error "Invalid hostname. Use letters, numbers, hyphens, or dots for FQDN."
        fi
    done

    read -rp "$(echo -e "${CYAN}Enter a 'pretty' hostname (optional): ${NC}")" PRETTY_NAME
    [[ -z "$PRETTY_NAME" ]] && PRETTY_NAME="$SERVER_NAME"

    while true; do
        read -rp "$(echo -e "${CYAN}Enter custom SSH port (1024-65535) [2222]: ${NC}")" SSH_PORT
        SSH_PORT=${SSH_PORT:-2222}
        if validate_port "$SSH_PORT"; then
            break
        else
            print_error "Invalid port. Must be a number between 1024 and 65535."
        fi
    done

    SERVER_IP=$(curl -s https://ifconfig.me 2>/dev/null || echo "unknown")
    print_info "Detected server IP: $SERVER_IP"

    echo -e "\n${YELLOW}Configuration Summary:${NC}"
    echo -e "${YELLOW}├─ Username:    ${NC}$USERNAME"
    echo -e "${YELLOW}├─ Hostname:    ${NC}$SERVER_NAME"
    echo -e "${YELLOW}├─ Pretty Name: ${NC}$PRETTY_NAME"
    echo -e "${YELLOW}├─ SSH Port:    ${NC}$SSH_PORT"
    echo -e "${YELLOW}└─ Server IP:   ${NC}$SERVER_IP"

    if ! confirm "\nContinue with this configuration?" "y"; then
        print_info "Configuration cancelled. Exiting."
        exit 0
    fi

    log "Configuration collected: USER=$USERNAME, HOST=$SERVER_NAME, PORT=$SSH_PORT"
}

configure_system() {
    print_section "System Configuration"

    # Create backup directory
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"

    # Backup critical files
    cp /etc/hosts "$BACKUP_DIR/hosts.backup"
    cp /etc/fstab "$BACKUP_DIR/fstab.backup"
    cp /etc/sysctl.conf "$BACKUP_DIR/sysctl.conf.backup" 2>/dev/null || true

    print_info "Setting timezone to UTC..."
    if ! timedatectl status | grep -q "Time zone: Etc/UTC"; then
        timedatectl set-timezone Etc/UTC
        print_success "Timezone set to UTC."
    else
        print_info "Timezone already set to UTC."
    fi

    if confirm "Configure system locales interactively?"; then
        dpkg-reconfigure locales
    else
        print_info "Skipping locale configuration."
    fi

    print_info "Configuring hostname..."
    if [[ $(hostnamectl --static) != "$SERVER_NAME" ]]; then
        hostnamectl set-hostname "$SERVER_NAME"
        hostnamectl set-hostname "$PRETTY_NAME" --pretty
        if grep -q "^127.0.1.1" /etc/hosts; then
            sed -i "s/^127.0.1.1.*/127.0.1.1\t$SERVER_NAME/" /etc/hosts
        else
            echo "127.0.1.1 $SERVER_NAME" >> /etc/hosts
        fi
        print_success "Hostname configured: $SERVER_NAME"
    else
        print_info "Hostname already set to $SERVER_NAME."
    fi

    log "System configuration completed."
}

install_packages() {
    print_section "Package Installation"

    print_info "Updating package lists..."
    if ! apt-get update -qq; then
        print_error "Failed to update package lists."
        exit 1
    fi

    print_info "Upgrading system packages..."
    if ! DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq; then
        print_error "Failed to upgrade system packages."
        exit 1
    fi

    print_info "Installing essential packages..."
    if ! apt-get install -y -qq \
        ufw fail2ban unattended-upgrades chrony \
        rsync wget vim \
        htop iotop nethogs ncdu tree \
        rsyslog cron jq gawk coreutils \
        perl skopeo git openssh-client; then
        print_error "Failed to install essential packages."
        exit 1
    fi

    print_success "Package installation complete."
    log "Package installation completed."
}

setup_user() {
    print_section "User Management"

    if [[ $USER_EXISTS == false ]]; then
        print_info "Creating user '$USERNAME'..."
        if ! adduser --disabled-password --gecos "" "$USERNAME"; then
            print_error "Failed to create user '$USERNAME'."
            exit 1
        fi
        print_info "Please set a password for the new user."
        if ! passwd "$USERNAME"; then
            print_error "Failed to set password for '$USERNAME'."
            exit 1
        fi
        print_success "User created: $USERNAME"
    else
        print_info "Using existing user: $USERNAME"
    fi

    print_info "Adding '$USERNAME' to sudo group..."
    if ! groups "$USERNAME" | grep -q sudo; then
        usermod -aG sudo "$USERNAME"
        print_success "User added to sudo group."
    else
        print_info "User '$USERNAME' already in sudo group."
    fi

    if sudo -u "$USERNAME" sudo -n true 2>/dev/null; then
        print_success "Sudo access confirmed for $USERNAME."
    else
        print_warning "Could not auto-verify sudo access for $USERNAME. Please test manually."
    fi

    log "User management completed for: $USERNAME."
}

configure_ssh() {
    print_section "SSH Hardening"

    # Detect current SSH port
    CURRENT_SSH_PORT=$(ss -tuln | grep -E ':.*\s+0.0.0.0:\*' | grep sshd | awk '{print $5}' | cut -d':' -f2 || echo "22")

    # Generate SSH key for the user if none exists
    print_info "Checking SSH key for user '$USERNAME'..."
    USER_HOME=$(getent passwd "$USERNAME" | cut -d: -f6)
    SSH_DIR="$USER_HOME/.ssh"
    SSH_KEY="$SSH_DIR/id_ed25519"

    if [[ ! -f "$SSH_KEY" ]]; then
        print_info "Generating new SSH key (ed25519) for '$USERNAME'..."
        mkdir -p "$SSH_DIR"
        chmod 700 "$SSH_DIR"
        chown "$USERNAME:$USERNAME" "$SSH_DIR"
        sudo -u "$USERNAME" ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -q
        cat "$SSH_KEY.pub" >> "$SSH_DIR/authorized_keys"
        chmod 600 "$SSH_DIR/authorized_keys"
        chown "$USERNAME:$USERNAME" "$SSH_DIR/authorized_keys"
        print_success "SSH key generated and added to authorized_keys."
        echo -e "${YELLOW}Public key for remote access:${NC}"
        cat "$SSH_KEY.pub" | tee -a "$LOG_FILE"
        echo -e "${YELLOW}Copy this key to your local ~/.ssh/authorized_keys or use 'ssh-copy-id -p $CURRENT_SSH_PORT $USERNAME@$SERVER_IP' from your local machine.${NC}"
    else
        print_info "SSH key already exists for '$USERNAME'. Skipping key generation."
    fi

    print_warning "SSH Key Setup Required!"
    echo -e "${YELLOW}Ensure you have copied the public key to your local machine or another secure location.${NC}"
    echo -e "${CYAN}Test SSH access now in a SEPARATE terminal: ssh -p $CURRENT_SSH_PORT $USERNAME@$SERVER_IP${NC}"
    echo

    if ! confirm "Can you successfully connect via SSH with the new key?"; then
        print_error "SSH key setup is mandatory. Please ensure key-based authentication works and re-run the script."
        exit 1
    fi

    print_info "Backing up original SSH config..."
    SSHD_BACKUP_FILE="$BACKUP_DIR/sshd_config.backup_$(date +%Y%m%d_%H%M%S)"
    cp /etc/ssh/sshd_config "$SSHD_BACKUP_FILE"

    # Check if SSH config already hardened
    if [[ ! -f /etc/ssh/sshd_config.d/99-hardening.conf ]]; then
        print_info "Creating hardened SSH configuration..."
        tee /etc/ssh/sshd_config.d/99-hardening.conf > /dev/null <<EOF
# Custom SSH Security Configuration
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
ClientAliveInterval 300
X11Forwarding no
PrintMotd no
Banner /etc/issue.net
EOF

        tee /etc/issue.net > /dev/null <<'EOF'
******************************************************************************
                        AUTHORIZED ACCESS ONLY
******************************************************************************
EOF
    else
        print_info "SSH configuration already hardened. Skipping."
    fi

    print_info "Testing SSH configuration..."
    if sshd -t; then
        print_success "SSH configuration test passed."
        systemctl restart sshd
        if systemctl is-active --quiet sshd; then
            print_success "SSH service restarted and active."
        else
            print_error "SSH service failed to start. Reverting changes."
            cp "$SSHD_BACKUP_FILE" /etc/ssh/sshd_config
            systemctl restart sshd
            exit 1
        fi
    else
        print_error "SSH configuration test failed! Reverting changes."
        cp "$SSHD_BACKUP_FILE" /etc/ssh/sshd_config
        systemctl restart sshd
        exit 1
    fi

    print_warning "CRITICAL: Test the new SSH connection in a SEPARATE terminal NOW!"
    print_info "Use this command: ssh -p $SSH_PORT $USERNAME@$SERVER_IP"

    if ! confirm "Was the new SSH connection successful?"; then
        print_error "Aborting. Restoring original SSH configuration."
        cp "$SSHD_BACKUP_FILE" /etc/ssh/sshd_config
        systemctl restart sshd
        exit 1
    fi

    log "SSH hardening completed on port $SSH_PORT."
}

configure_firewall() {
    print_section "Firewall Configuration (UFW)"

    # Check if UFW is already enabled
    if ufw status | grep -q "Status: active"; then
        print_info "UFW already enabled. Checking rules..."
    else
        print_info "Configuring UFW default policies..."
        ufw default deny incoming
        ufw default allow outgoing
    fi

    # Add SSH rule only if not already present
    if ! ufw status | grep -q "$SSH_PORT/tcp"; then
        print_info "Adding SSH rule for port $SSH_PORT..."
        ufw allow "$SSH_PORT"/tcp comment 'Custom SSH'
    else
        print_info "SSH rule for port $SSH_PORT already exists."
    fi

    if confirm "Allow HTTP traffic (port 80)?"; then
        if ! ufw status | grep -q "80/tcp"; then
            ufw allow 80/tcp comment 'HTTP'
            print_success "HTTP traffic allowed."
        else
            print_info "HTTP rule already exists."
        fi
    fi

    if confirm "Allow HTTPS traffic (port 443)?"; then
        if ! ufw status | grep -q "443/tcp"; then
            ufw allow 443/tcp comment 'HTTPS'
            print_success "HTTPS traffic allowed."
        else
            print_info "HTTPS rule already exists."
        fi
    fi

    print_info "Enabling firewall..."
    ufw enable

    print_success "Firewall is active."
    ufw status verbose | tee -a "$LOG_FILE"

    log "Firewall configuration completed."
}

configure_fail2ban() {
    print_section "Fail2Ban Configuration"

    if [[ ! -f /etc/fail2ban/jail.local ]]; then
        print_info "Creating Fail2Ban local jail configuration..."
        tee /etc/fail2ban/jail.local > /dev/null <<EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 3
backend = auto

[sshd]
enabled = true
port = $SSH_PORT
EOF
    else
        print_info "Fail2Ban configuration already exists. Updating port if needed..."
        sed -i "s/port = .*/port = $SSH_PORT/" /etc/fail2ban/jail.local
    fi

    print_info "Enabling and restarting Fail2Ban..."
    systemctl enable fail2ban
    systemctl restart fail2ban
    sleep 2 # Give service time to initialize

    if systemctl is-active --quiet fail2ban; then
        print_success "Fail2Ban is active and monitoring port $SSH_PORT."
        fail2ban-client status sshd | tee -a "$LOG_FILE"
    else
        print_error "Fail2Ban service failed to start."
    fi

    log "Fail2Ban configuration completed."
}

configure_auto_updates() {
    print_section "Automatic Security Updates"

    if confirm "Enable automatic security updates via unattended-upgrades?"; then
        if ! dpkg -l unattended-upgrades | grep -q ^ii; then
            print_error "unattended-upgrades package not installed."
            exit 1
        fi
        print_info "Configuring unattended upgrades..."
        echo "unattended-upgrades unattended-upgrades/enable_auto_updates boolean true" | debconf-set-selections
        DEBIAN_FRONTEND=noninteractive dpkg-reconfigure -fnoninteractive unattended-upgrades
        print_success "Automatic updates enabled."
    else
        print_info "Skipping automatic updates."
    fi

    log "Automatic updates configuration completed."
}

install_docker() {
    if ! confirm "Install Docker Engine (Optional)?"; then
        print_info "Skipping Docker installation."
        return 0
    fi

    print_section "Docker Installation"

    if command -v docker >/dev/null 2>&1; then
        print_info "Docker already installed. Skipping."
        return 0
    fi

    print_info "Removing old container runtimes..."
    apt-get remove -y -qq docker docker-engine docker.io containerd runc 2>/dev/null || true

    print_info "Adding Docker's official GPG key and repository..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/${ID}/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list

    print_info "Installing Docker packages..."
    if ! apt-get update -qq || ! apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
        print_error "Failed to install Docker packages."
        exit 1
    fi

    print_info "Creating Docker group if it doesn't exist..."
    getent group docker >/dev/null || groupadd docker

    print_info "Adding '$USERNAME' to docker group..."
    if ! groups "$USERNAME" | grep -q docker; then
        usermod -aG docker "$USERNAME"
        print_success "User '$USERNAME' added to docker group."
    else
        print_info "User '$USERNAME' already in docker group."
    fi

    print_info "Configuring Docker daemon with log rotation..."
    if [[ ! -f /etc/docker/daemon.json ]]; then
        tee /etc/docker/daemon.json > /dev/null <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "live-restore": true
}
EOF
    fi

    systemctl daemon-reload
    systemctl enable docker
    systemctl restart docker

    print_info "Running Docker sanity check..."
    if sudo -u "$USERNAME" docker run --rm hello-world 2>&1 | tee -a "$LOG_FILE" | grep -q "Hello from Docker"; then
        print_success "Docker sanity check passed."
    else
        print_error "Docker hello-world test failed. Please verify Docker installation manually."
    fi

    print_success "Docker installation completed."
    print_warning "NOTE: '$USERNAME' must log out and back in to use Docker without sudo."
    log "Docker installation completed."
}

install_tailscale() {
    if ! confirm "Install Tailscale VPN (Optional)?"; then
        print_info "Skipping Tailscale installation."
        return 0
    fi

    print_section "Tailscale VPN Installation"

    if command -v tailscale >/dev/null 2>&1; then
        print_info "Tailscale already installed. Skipping."
        return 0
    fi

    print_info "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh -o /tmp/tailscale_install.sh
    chmod +x /tmp/tailscale_install.sh
    if ! /tmp/tailscale_install.sh; then
        print_error "Failed to install Tailscale."
        rm -f /tmp/tailscale_install.sh
        exit 1
    fi
    rm -f /tmp/tailscale_install.sh

    print_warning "ACTION REQUIRED: Run 'tailscale up' after this script finishes."

    print_success "Tailscale installation package is complete."
    log "Tailscale installation completed."
}

configure_swap() {
    if [[ $IS_CONTAINER == true ]]; then
        print_info "Swap configuration skipped in container environment."
        return 0
    fi

    print_section "Swap Configuration"

    if swapon --show | grep -q '/swapfile'; then
        print_info "Swap file already exists. Skipping."
        return 0
    fi

    if ! confirm "Configure a 2GB swap file (Recommended for < 4GB RAM)?"; then
        print_info "Skipping swap configuration."
        return 0
    fi

    # Check disk space
    REQUIRED_SPACE=$((2 * 1024 * 1024)) # 2GB in KB
    AVAILABLE_SPACE=$(df -k / | tail -n 1 | awk '{print $4}')
    if [[ $AVAILABLE_SPACE -lt $REQUIRED_SPACE ]]; then
        print_error "Insufficient disk space for 2GB swap file. Available: $((AVAILABLE_SPACE / 1024))MB"
        return 1
    fi

    print_info "Creating 2GB swap file..."
    if ! fallocate -l 2G /swapfile; then
        print_error "Failed to create swap file."
        return 1
    fi
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile

    if ! grep -q '^/swapfile ' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    print_info "Optimizing swap settings (vm.swappiness=10)..."
    if ! grep -q 'vm.swappiness=10' /etc/sysctl.conf; then
        echo 'vm.swappiness=10' >> /etc/sysctl.conf
        echo 'vm.vfs_cache_pressure=50' >> /etc/sysctl.conf
        sysctl -p > /dev/null
    fi

    print_info "Verifying swap configuration..."
    swapon --show | tee -a "$LOG_FILE"
    free -h | tee -a "$LOG_FILE"
    print_success "Swap configured successfully."

    systemctl daemon-reload
    log "Swap configuration completed."
}

configure_time_sync() {
    print_section "Time Synchronization Configuration"

    print_info "Ensuring chrony is active..."
    systemctl enable chrony
    systemctl restart chrony
    sleep 2 # Allow service to initialize

    if systemctl is-active --quiet chrony; then
        print_success "Chrony is active and time synchronization is enabled."
        chronyc tracking | tee -a "$LOG_FILE"
    else
        print_error "Chrony service failed to start."
        exit 1
    fi

    log "Time synchronization configuration completed."
}

final_cleanup() {
    print_section "Final System Cleanup"

    print_info "Running final system update and cleanup..."
    if apt-get update -qq && apt-get upgrade -y -qq && apt-get autoremove -y -qq; then
        print_success "Final system update and cleanup complete."
    else
        print_error "Final system cleanup failed."
        exit 1
    fi
    systemctl daemon-reload
    log "Final system cleanup completed."
}

generate_summary() {
    print_section "Setup Complete!"

    print_section "Verifying Final Setup"
    print_info "Checking firewall status..."
    ufw status verbose | tee -a "$LOG_FILE"

    print_info "Checking swap configuration..."
    swapon --show | tee -a "$LOG_FILE"

    print_info "Checking time synchronization..."
    timedatectl | tee -a "$LOG_FILE"

    if command -v docker >/dev/null 2>&1; then
        print_info "Checking Docker status..."
        docker ps | tee -a "$LOG_FILE"
    fi

    if command -v tailscale >/dev/null 2>&1; then
        print_info "Checking Tailscale status..."
        tailscale status | tee -a "$LOG_FILE"
    fi

    print_info "Checking critical services..."
    for service in sshd ufw fail2ban chrony; do
        if systemctl is-active --quiet "$service"; then
            print_success "Service $service is active."
        else
            print_error "Service $service is not active."
        fi
    done
    if command -v docker >/dev/null 2>&1; then
        if systemctl is-active --quiet docker; then
            print_success "Service docker is active."
        else
            print_error "Service docker is not active."
        fi
    fi
    systemctl is-active sshd ufw fail2ban chrony docker 2>/dev/null | tee -a "$LOG_FILE"

    echo -e "${GREEN}Server hardening script has finished successfully.${NC}"
    echo
    echo -e "${YELLOW}Configuration Summary:${NC}"
    echo -e "${YELLOW}├─ Admin User: ${NC}$USERNAME"
    echo -e "${YELLOW}├─ Hostname:   ${NC}$SERVER_NAME"
    echo -e "${YELLOW}├─ SSH Port:   ${NC}$SSH_PORT"
    echo -e "${YELLOW}└─ Server IP:  ${NC}$SERVER_IP"
    echo
    echo -e "${PURPLE}A detailed log of this session is available at: ${LOG_FILE}${NC}"
    echo -e "${PURPLE}Backups of critical files are stored in: ${BACKUP_DIR}${NC}"
    echo
    echo -e "${CYAN}Post-Reboot Verification Steps:${NC}"
    echo -e "${CYAN}  - Check SSH access: ${NC}ssh -p $SSH_PORT -v $USERNAME@$SERVER_IP"
    echo -e "${CYAN}  - Verify firewall rules: ${NC}ufw status verbose"
    echo -e "${CYAN}  - Check time sync: ${NC}chronyc tracking"
    echo -e "${CYAN}  - Check Fail2Ban: ${NC}fail2ban-client status sshd"
    echo -e "${CYAN}  - Verify swap: ${NC}swapon --show && free -h"
    if command -v docker >/dev/null 2>&1; then
        echo -e "${CYAN}  - Test Docker: ${NC}docker run --rm hello-world"
    fi
    if command -v tailscale >/dev/null 2>&1; then
        echo -e "${CYAN}  - Check Tailscale: ${NC}tailscale status"
    fi
    print_warning "A reboot is required to apply all changes cleanly."
    if [[ $VERBOSE == true ]]; then
        if confirm "Reboot now?" "y"; then
            print_info "Rebooting now... Press Enter to proceed or Ctrl+C to cancel."
            read -r
            reboot
        else
            print_warning "Please reboot the server manually by running 'reboot'."
        fi
    else
        print_warning "Running in quiet mode. Please reboot the server manually by running 'reboot'."
    fi

    log "Script finished successfully."
}

handle_error() {
    local exit_code=$?
    local line_no="$1"
    print_error "An error occurred on line $line_no (exit code: $exit_code)."
    print_info "Check the log file for details: $LOG_FILE"
    print_info "Backups are available in: $BACKUP_DIR"
    exit $exit_code
}

main() {
    trap 'handle_error $LINENO' ERR

    print_header

    # Create log file with correct permissions
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"

    log "Starting Debian/Ubuntu hardening script."

    check_dependencies
    check_system
    collect_config
    configure_system
    install_packages
    setup_user
    configure_ssh
    configure_firewall
    configure_fail2ban
    configure_auto_updates
    configure_time_sync
    install_docker
    install_tailscale
    configure_swap
    final_cleanup
    generate_summary
}

# Run main function
main "$@"
