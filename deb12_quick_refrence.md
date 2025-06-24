### **Debian 12 Server - Quick Reference**

⚠️ **IMPORTANT:** Read each section completely before executing commands. It is highly recommended to test SSH connections in a separate, dedicated terminal before closing your original session.

#### **Pre-Setup Variables**

Define these variables once before starting. The rest of the script will use them automatically.

```bash
# --- REPLACE THESE WITH YOUR ACTUAL VALUES ---
USERNAME="yourusername"           # Your new admin username
SERVER_NAME="myserver"           # Your server's hostname (e.g., web-prod-01)
SSH_PORT="2222"                  # Your custom SSH port (1024-65535)
SERVER_IP="your.server.ip"       # Your server's public IP address
# --- END OF VARIABLES ---
```

-----

#### **1. Initial System Configuration**

##### **Set Timezone and Locales**

```bash
# Set timezone to UTC (recommended for servers)
sudo timedatectl set-timezone Etc/UTC
timedatectl status  # Verify

# Configure locales (opens an interactive menu)
sudo dpkg-reconfigure locales
```

##### **Configure Hostname**

```bash
# Set the system hostname
sudo hostnamectl set-hostname "${SERVER_NAME}"
sudo hostnamectl set-hostname "My Production Server" --pretty

# Update the hosts file to map the new hostname
sudo sed -i "s/127.0.1.1.*/127.0.1.1\t${SERVER_NAME}/" /etc/hosts

# Verify the changes
hostnamectl status
```

#### **2. Package Management**

```bash
# Update package lists and upgrade all system packages
sudo apt update && sudo apt upgrade -y

# Install a comprehensive set of security and utility packages
sudo apt install -y \
    ufw fail2ban unattended-upgrades \
    rsync curl wget nano vim \
    htop iotop nethogs ncdu tree \
    rsyslog cron jq gawk coreutils \
    perl skopeo git
```

#### **3. User Management & Security**

```bash
# Create the new administrative user
sudo adduser "${USERNAME}"

# Add the new user to the sudo group for administrative privileges
sudo usermod -aG sudo "${USERNAME}"

# Test sudo access by switching to the new user
su - "${USERNAME}"
sudo whoami  # This command should return 'root'
exit         # Return to your original session to continue the setup
```

#### **4. SSH Security Hardening**

⚠️ **CRITICAL:** Complete all steps in this section. Test the new SSH connection in a separate terminal before closing your original one.

##### **Step 1: Generate & Copy SSH Key (On Your LOCAL Machine)**

```bash
# --- RUN THESE COMMANDS ON YOUR LOCAL MACHINE, NOT THE SERVER ---

# Generate a new, secure ed25519 SSH key if you don't have one
ssh-keygen -t ed25519 -C "your-email@example.com"

# Copy the public key to the server (use port 22 for the initial connection)
ssh-copy-id "${USERNAME}@${SERVER_IP}"

# Test your key-based login to ensure it works before proceeding
ssh "${USERNAME}@${SERVER_IP}"
```

##### **Step 2: Configure & Harden the SSH Server (On The SERVER)**

```bash
# --- RUN THESE COMMANDS ON THE SERVER ---

# Backup the original SSH configuration file as a precaution
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup

# Create a modern drop-in configuration file for hardening (cleaner than editing the main file)
sudo tee /etc/ssh/sshd_config.d/99-hardening.conf > /dev/null <<EOF
# Custom SSH Security Configuration
Port ${SSH_PORT}
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
PrintMotd no
Banner /etc/issue.net
EOF

# Create the security banner file referenced in the configuration
sudo tee /etc/issue.net > /dev/null <<EOF
******************************************************************************
                            AUTHORIZED ACCESS ONLY
                    This system is for authorized users only.
                   All activities are logged and monitored.
******************************************************************************
EOF

# Test the SSH configuration syntax for errors
sudo sshd -t

# If the test passes ("syntax is ok"), restart the SSH service to apply changes
sudo systemctl restart sshd
```

##### **Step 3: Test the New SSH Configuration**

⚠️ **IMPORTANT:** Keep your current session open\! Open a **new terminal window** and test the connection with the new settings.

```bash
# --- RUN THIS IN A NEW LOCAL TERMINAL ---
ssh -p "${SSH_PORT}" "${USERNAME}@${SERVER_IP}"

# If the connection is successful, you can safely close your original session.
```

#### **5. Firewall Configuration (UFW)**

```bash
# Set default policies to deny all incoming and allow all outgoing traffic
sudo ufw default deny incoming
sudo ufw default allow outgoing

# Allow the custom SSH port (CRITICAL - DO THIS FIRST!)
sudo ufw allow "${SSH_PORT}"/tcp comment 'Custom SSH'

# Allow ping requests (ICMP), which is useful for diagnostics
sudo ufw allow icmp

# Allow standard web services (if this server will host a website)
sudo ufw allow 80/tcp comment 'HTTP'
sudo ufw allow 443/tcp comment 'HTTPS'

# Enable the firewall (will prompt for confirmation)
sudo ufw enable

# Verify the configuration
sudo ufw status verbose
```

#### **6. Fail2Ban Intrusion Prevention**

```bash
# Create a local configuration file to override defaults and watch our custom SSH port
sudo tee /etc/fail2ban/jail.local > /dev/null <<EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 3
backend = systemd

[sshd]
enabled = true
port = ${SSH_PORT}
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
EOF

# Enable and start the Fail2Ban service
sudo systemctl enable fail2ban
sudo systemctl restart fail2ban

# Verify that Fail2Ban is running and monitoring the sshd jail
sudo fail2ban-client status
sudo fail2ban-client status sshd
```

#### **7. Automatic Security Updates**

```bash
# This command opens an interactive dialog to enable automatic security updates
sudo dpkg-reconfigure -plow unattended-upgrades
# At the prompt, select "Yes" to enable.
```

#### **8. Docker Installation (Optional)**

```bash
# Remove any conflicting old packages
sudo apt remove -y docker.io docker-doc docker-compose podman-docker containerd runc

# Add Docker's official GPG key and repository
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install the Docker packages
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Add your user to the 'docker' group to run Docker commands without sudo
sudo usermod -aG docker "${USERNAME}"

# Configure the Docker daemon with log rotation and live restore capabilities
sudo tee /etc/docker/daemon.json > /dev/null <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "live-restore": true
}
EOF

# Enable and restart the Docker service
sudo systemctl enable docker
sudo systemctl restart docker

# Test the installation. You may need to logout and log back in first.
docker run hello-world
```

#### **9. Tailscale VPN (Optional)**

```bash
# Install Tailscale using the official script
curl -fsSL https://tailscale.com/install.sh | sh

# Connect your server to your Tailscale network (will provide a login URL)
sudo tailscale up

# Optional: Allow your user to control Tailscale without sudo
sudo tailscale set --operator="${USERNAME}"

# Verify the connection status and get your Tailscale IP address
tailscale status
tailscale ip -4
```

#### **10. Memory Management (Swap)**

Recommended for systems with 4GB of RAM or less.

```bash
# Create a 2GB swap file
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile

# Make the swap file permanent across reboots
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab

# Optimize swap usage to prefer RAM (lower swappiness)
echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf
echo 'vm.vfs_cache_pressure=50' | sudo tee -a /etc/sysctl.conf

# Verify that swap is active
free -h
swapon --show
```

#### **11. Final System Configuration**

```bash
# Enable network time synchronization to keep the clock accurate
sudo timedatectl set-ntp true

# Verify NTP status
timedatectl status

# Run a final update and remove any orphaned packages
sudo apt update && sudo apt upgrade -y && sudo apt autoremove -y

# Reboot the server to apply all changes cleanly
sudo reboot
```

-----

### **Post-Reboot Verification & Operations**

#### **Security Checklist**

Run these commands after rebooting to verify your setup.

  * **SSH Access:** `ssh -p "${SSH_PORT}" "${USERNAME}@${SERVER_IP}"`
  * **Firewall Status:** `sudo ufw status verbose`
  * **Fail2Ban Status:** `sudo fail2ban-client status sshd`
  * **System Services:** `sudo systemctl status sshd fail2ban ufw`
  * **System Resources:** `free -h && df -h && timedatectl`
  * **Optional Services:** `docker ps` and `tailscale status` (if installed)

#### **Maintenance Commands**

  * **System Cleanup:** `sudo apt update && sudo apt upgrade -y && sudo apt autoremove -y`
  * **Docker Cleanup:** `docker system prune -f && docker image prune -f`
  * **Log Cleanup:** `sudo journalctl --vacuum-time=30d`
  * **Check for Security Updates:** `sudo apt list --upgradable | grep -i security`

#### **Emergency Recovery**

If you get locked out, use your provider's web console/VNC to:

1.  **Check Service Status:** `sudo systemctl status sshd ufw fail2ban`
2.  **Check SSH Config:** `sudo sshd -t`
3.  **Reset Firewall (if needed):** `sudo ufw reset` and re-apply rules.
4.  **Restore SSH Config:** `sudo cp /etc/ssh/sshd_config.backup /etc/ssh/sshd_config` and `sudo systemctl restart sshd`.
5.  **Stop Fail2Ban:** `sudo systemctl stop fail2ban`
