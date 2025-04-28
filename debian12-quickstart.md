## Debian Server Quick Start (April 2025)

    Initial Root Access: Log in to your new Debian server using the root account provided by your hosting provider.

    Create a New User with Sudo Access:
    Bash

adduser your-new-username
usermod -aG sudo your-new-username

Set a strong, unique password for this new user when prompted.

Set Up SSH Key-Based Authentication (Highly Recommended):

    On your local machine: Generate an SSH key pair if you don't have one already:
    Bash

ssh-keygen -t rsa -b 4096

This will create a private key (e.g., ~/.ssh/id_rsa) and a public key (e.g., ~/.ssh/id_rsa.pub). Keep the private key secure and do not share it.
On the Debian server:
Bash

su - your-new-username
mkdir -p ~/.ssh
chmod 700 ~/.ssh
nano ~/.ssh/authorized_keys

Paste the contents of your local machine's public key file (~/.ssh/id_rsa.pub) into the ~/.ssh/authorized_keys file on the server.
Save and close the file.
Restrict permissions on the authorized_keys file:
Bash

    chmod 600 ~/.ssh/authorized_keys
    exit # Back to root user

Install and Configure UFW Firewall:
Bash

apt update
apt install -y ufw
ufw allow 5599/tcp
ufw default deny incoming
ufw default allow outgoing
ufw enable
ufw status verbose

Change SSH Port:

    Edit /etc/ssh/sshd_config:
    Bash

sudo nano /etc/ssh/sshd_config

Uncomment or add Port 5599.
Save and close the file.
Restart SSH service:
Bash

    sudo systemctl restart sshd

Disable Root SSH Login and Password Authentication:

    Edit /etc/ssh/sshd_config:
    Bash

sudo nano /etc/ssh/sshd_config

Set PermitRootLogin no.
Set PasswordAuthentication no.
Save and close the file.
Restart SSH service:
Bash

    sudo systemctl restart sshd

Set Hostname and Pretty Hostname:
Bash

sudo hostnamectl set-hostname your-chosen-hostname
sudo hostnamectl set-hostname "Your Pretty Hostname" --pretty
sudo nano /etc/hosts # Update the line with 127.0.0.1 to include the new hostname

Set Timezone (Current Time in London is 2:46 PM BST):
Bash

sudo timedatectl set-timezone Europe/London

Configure Locale:
Bash

sudo dpkg-reconfigure locales

Install Essential Utilities (Recommended):
Bash

sudo apt update
sudo apt install -y vim curl wget net-tools tmux htop apt-transport-https ca-certificates gnupg

    apt-transport-https, ca-certificates, gnupg: Often needed for adding external repositories securely.

Set Up Automated Security Updates:
Bash

sudo apt install -y unattended-upgrades apt-listchanges
sudo dpkg-reconfigure unattended-upgrades

Carefully review the options and ensure that security updates are set to be installed automatically. You can further customize the behavior by editing /etc/apt/apt.conf.d/50unattended-upgrades. Pay attention to the Unattended-Upgrade::Allowed-Origins section.

Basic System Information Check: Get familiar with commands like:
Bash

uname -a
lsb_release -a
df -h
free -h

Consider Installing Fail2ban: This tool helps protect your server from brute-force attacks.
Bash

sudo apt update
sudo apt install -y fail2ban
sudo systemctl enable fail2ban
sudo systemctl start fail2ban
sudo fail2ban-client status # Check its status

You might want to configure the /etc/fail2ban/jail.conf or create a local configuration file in /etc/fail2ban/jail.d/ to customize the rules (e.g., for SSH on the new port).

Basic Security Hardening:

    Disable unnecessary services: List running services with systemctl list-unit-files --state=enabled. Disable any services you don't need using sudo systemctl disable <service_name>.
    Keep software up to date: Regularly run sudo apt update && sudo apt upgrade.
    Review open ports: Use netstat -tuln or ss -tuln to see what ports are listening. Ensure only necessary ports are open (in your case, likely just 5599 for SSH).

Initial Backup Strategy Planning: Decide on a backup solution from the start. This could involve:

    Using tools like rsync to copy important data to another location.
    Exploring backup software or services offered by your VPS provider.
    Considering snapshotting capabilities if your VPS provider offers them.

Resource Monitoring: Install tools to monitor your server's resource usage:
Bash

sudo apt install -y atop # More advanced than htop

Regularly check CPU, memory, and disk usage to identify potential issues early.

Log Rotation: Debian usually configures log rotation automatically, but it's good to be aware of it. Logs are typically stored in /var/log/ and rotated using logrotate to prevent them from filling up your disk.

SELinux or AppArmor (Optional, More Advanced): For enhanced security, you could explore Security-Enhanced Linux (SELinux) or AppArmor. Debian uses AppArmor by default. You can check its status with sudo systemctl status apparmor. Configuring these requires a deeper understanding of system security policies.
