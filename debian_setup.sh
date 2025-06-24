#!/bin/bash

# Debian 12 Server Hardening Interactive Script
# Version: 2.1 (Reviewed & Corrected)
# Compatible with: Debian 12 (Bookworm)

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
LOG_FILE="/var/log/debian_hardening_$(date +%Y%m%d_%H%M%S).log"

# Logging function
log() {
    # Prepend date and time to the message and append to the log file
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Print functions
print_header() {
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                                                          ║${NC}"
    echo -e "${CYAN}║            DEBIAN 12 SERVER HARDENING SCRIPT             ║${NC}"
    echo -e "${CYAN}║                                                          ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo
}

print_section() {
    echo -e "\n${BLUE}▓▓▓ $1 ▓▓▓${NC}" | tee -a "$LOG_FILE"
    echo -e "${BLUE}$(printf '═%.0s' {1..60})${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}" | tee -a "$LOG_FILE"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}" | tee -a "$LOG_FILE"
}

print_error() {
    echo -e "${RED}✗ $1${NC}" | tee -a "$LOG_FILE"
}

print_info() {
    echo -e "${PURPLE}ℹ $1${NC}" | tee -a "$LOG_FILE"
}

# Confirmation function for user prompts
confirm() {
    local prompt="$1"
    local default="${2:-n}"
    local response

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
    if [[ ! $hostname =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,61}[a-zA-Z0-9]$ ]]; then
        return 1
    fi
    return 0
}

validate_port() {
    local port="$1"
    if [[ ! $port =~ ^[0-9]+$ ]] || [[ $port -lt 1024 ]] || [[ $port -gt 65535 ]]; then
        return 1
    fi
    return 0
}

# --- Core Script Functions ---

check_system() {
    print_section "System Compatibility Check"
    
    # CORRECTED: This script must be run by root on a new server to create the first admin user.
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root or with sudo."
        print_info "Example: sudo ./this_script.sh"
        exit 1
    fi
    print_success "Running with root privileges."
    
    # Check Debian version
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        if [[ $ID == "debian" && $VERSION_ID == "12" ]]; then
            print_success "Debian 12 (Bookworm) detected."
        else
            print_warning "This script is designed for Debian 12. Detected: $PRETTY_NAME"
            if ! confirm "Continue anyway?"; then
                exit 1
            fi
        fi
    else
        print_error "This doesn't appear to be a Debian system."
        exit 1
    fi
    
    # Check internet connectivity
    if ping -c 1 8.8.8.8 &> /dev/null; then
        print_success "Internet connectivity confirmed."
    else
        print_error "No internet connectivity. Please check your network."
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
            print_error "Invalid hostname. Use letters, numbers, and hyphens."
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
    
    SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || echo "unknown")
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
    
    print_info "Setting timezone to UTC..."
    timedatectl set-timezone Etc/UTC
    print_success "Timezone set to UTC."
    
    if confirm "Configure system locales interactively?"; then
        dpkg-reconfigure locales
    else
        print_info "Skipping locale configuration."
    fi
    
    print_info "Configuring hostname..."
    hostnamectl set-hostname "$SERVER_NAME"
    hostnamectl set-hostname "$PRETTY_NAME" --pretty
    
    if grep -q "^127.0.1.1" /etc/hosts; then
        sed -i "s/^127.0.1.1.*/127.0.1.1\t$SERVER_NAME/" /etc/hosts
    else
        echo "127.0.1.1 $SERVER_NAME" >> /etc/hosts
    fi
    
    print_success "Hostname configured: $SERVER_NAME"
    log "System configuration completed."
}

install_packages() {
    print_section "Package Installation"
    
    print_info "Updating package lists..."
    apt-get update -qq
    
    print_info "Upgrading system packages..."
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
    
    print_info "Installing essential packages..."
    apt-get install -y -qq \
        ufw fail2ban unattended-upgrades \
        rsync curl wget nano vim \
        htop iotop nethogs ncdu tree \
        rsyslog cron jq gawk coreutils \
        perl skopeo git
    
    print_success "Package installation complete."
    log "Package installation completed."
}

setup_user() {
    print_section "User Management"
    
    if [[ $USER_EXISTS == false ]]; then
        print_info "Creating user '$USERNAME'..."
        adduser --disabled-password --gecos "" "$USERNAME"
        print_info "Please set a password for the new user."
        passwd "$USERNAME"
        print_success "User created: $USERNAME"
    else
        print_info "Using existing user: $USERNAME"
    fi
    
    print_info "Adding '$USERNAME' to sudo group..."
    usermod -aG sudo "$USERNAME"
    print_success "User added to sudo group."
    
    if sudo -u "$USERNAME" sudo -n true 2>/dev/null; then
        print_success "Sudo access confirmed for $USERNAME."
    else
        print_warning "Could not auto-verify sudo access for $USERNAME. Please test manually."
    fi
    
    log "User management completed for: $USERNAME."
}

configure_ssh() {
    print_section "SSH Hardening"

    print_warning "SSH Key Setup Required!"
    echo -e "${YELLOW}To continue, you MUST copy your SSH public key to the new user on this server.${NC}"
    echo -e "${YELLOW}Please run this command on your LOCAL machine (NOT this server):${NC}"
    echo -e "${CYAN}ssh-copy-id -p 22 ${USERNAME}@${SERVER_IP}${NC}"
    echo
    
    if ! confirm "Have you successfully copied your SSH key to the server?"; then
        print_error "SSH key setup is mandatory. Please copy your key and re-run the script."
        exit 1
    fi
    
    print_info "Backing up original SSH config..."
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
    
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

    print_info "Testing SSH configuration..."
    if sshd -t; then
        print_success "SSH configuration test passed."
        systemctl restart sshd
        print_success "SSH service restarted."
    else
        print_error "SSH configuration test failed! Reverting changes."
        cp /etc/ssh/sshd_config.backup /etc/ssh/sshd_config
        exit 1
    fi
    
    print_warning "CRITICAL: Test the new SSH connection in a SEPARATE terminal NOW!"
    print_info "Use this command: ssh -p $SSH_PORT $USERNAME@$SERVER_IP"
    
    if ! confirm "Was the new SSH connection successful?"; then
        print_error "Aborting. Your original SSH configuration has been restored."
        cp /etc/ssh/sshd_config.backup /etc/ssh/sshd_config
        systemctl restart sshd
        exit 1
    fi
    
    log "SSH hardening completed on port $SSH_PORT."
}

configure_firewall() {
    print_section "Firewall Configuration (UFW)"
    
    print_info "Configuring UFW default policies..."
    # CORRECTED: Removed invalid --force flag from default commands
    ufw default deny incoming
    ufw default allow outgoing
    
    print_info "Adding SSH rule for port $SSH_PORT..."
    ufw allow "$SSH_PORT"/tcp comment 'Custom SSH'
    
    if confirm "Allow HTTP traffic (port 80)?"; then
        ufw allow 80/tcp comment 'HTTP'
        print_success "HTTP traffic allowed."
    fi
    
    if confirm "Allow HTTPS traffic (port 443)?"; then
        ufw allow 443/tcp comment 'HTTPS'
        print_success "HTTPS traffic allowed."
    fi
    
    print_info "Enabling firewall..."
    ufw --force enable
    
    print_success "Firewall is active."
    ufw status verbose | tee -a "$LOG_FILE"
    
    log "Firewall configuration completed."
}

configure_fail2ban() {
    print_section "Fail2Ban Configuration"
    
    print_info "Creating Fail2Ban local jail configuration..."
    tee /etc/fail2ban/jail.local > /dev/null <<EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 3
backend = systemd

[sshd]
enabled = true
port = $SSH_PORT
EOF
    
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
        print_info "Configuring unattended upgrades..."
        # Use non-interactive frontend to pre-seed the correct answer
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
    
    print_info "Adding Docker's official GPG key and repository..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
    
    print_info "Installing Docker packages..."
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    print_info "Adding '$USERNAME' to docker group..."
    usermod -aG docker "$USERNAME"
    
    print_info "Configuring Docker daemon with log rotation..."
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
    
    systemctl enable docker
    systemctl restart docker
    
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
    
    print_info "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
    
    print_warning "ACTION REQUIRED: Run 'sudo tailscale up' after this script finishes."
    
    print_success "Tailscale installation package is complete."
    log "Tailscale installation completed."
}

configure_swap() {
    if swapon --show | grep -q '/swapfile'; then
        print_info "Swap file already detected. Skipping."
        return 0
    fi

    if ! confirm "Configure a 2GB swap file (Recommended for < 4GB RAM)?"; then
        print_info "Skipping swap configuration."
        return 0
    fi
    
    print_section "Swap Configuration"
    
    print_info "Creating 2GB swap file..."
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    
    if ! grep -q '^/swapfile ' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    
    print_info "Optimizing swap settings (vm.swappiness=10)..."
    sed -i '/vm.swappiness/d' /etc/sysctl.conf
    sed -i '/vm.vfs_cache_pressure/d' /etc/sysctl.conf
    echo 'vm.swappiness=10' >> /etc/sysctl.conf
    echo 'vm.vfs_cache_pressure=50' >> /etc/sysctl.conf
    sysctl -p > /dev/null
    
    print_success "Swap configured successfully."
    free -h | tee -a "$LOG_FILE"
    log "Swap configuration completed."
}

final_cleanup() {
    print_section "Final System Cleanup"
    
    print_info "Running final system update and cleanup..."
    DEBIAN_FRONTEND=noninteractive apt-get update -qq && apt-get upgrade -y -qq && apt-get autoremove -y -qq
    
    print_info "Enabling NTP for time synchronization..."
    timedatectl set-ntp true
    
    print_success "Final cleanup complete."
    log "Final system configuration completed."
}

generate_summary() {
    print_section "Setup Complete!"
    
    echo -e "${GREEN}Server hardening script has finished successfully.${NC}"
    echo
    echo -e "${YELLOW}Configuration Summary:${NC}"
    echo -e "${YELLOW}├─ Admin User:  ${NC}$USERNAME"
    echo -e "${YELLOW}├─ Hostname:    ${NC}$SERVER_NAME"
    echo -e "${YELLOW}├─ SSH Port:    ${NC}$SSH_PORT"
    echo -e "${YELLOW}└─ Server IP:   ${NC}$SERVER_IP"
    echo
    echo -e "${PURPLE}A detailed log of this session is available at: ${LOG_FILE}${NC}"
    echo
    
    print_warning "A reboot is required to apply all changes cleanly."
    if confirm "Reboot now?" "y"; then
        print_info "Rebooting in 5 seconds... (Press Ctrl+C to cancel)"
        sleep 5
        reboot
    else
        print_warning "Please reboot the server manually by running 'sudo reboot'."
    fi
    
    log "Script finished successfully."
}

handle_error() {
    local exit_code=$?
    local line_no=$1
    print_error "An error occurred on line $line_no (exit code: $exit_code)."
    print_info "Check the log file for details: $LOG_FILE"
    exit $exit_code
}

main() {
    trap 'handle_error $LINENO' ERR
    
    print_header
    
    # Create log file with correct permissions
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"

    log "Starting Debian 12 hardening script."
    
    check_system
    collect_config
    configure_system
    install_packages
    setup_user
    configure_ssh
    configure_firewall
    configure_fail2ban
    configure_auto_updates
    install_docker
    install_tailscale
    configure_swap
    final_cleanup
    generate_summary
}

# Run main function, passing all arguments to it
main "$@"
