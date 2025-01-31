# Setting up UFW Firewall on Ubuntu Server

This guide provides a comprehensive walkthrough of setting up and configuring the Uncomplicated Firewall (UFW) on an Ubuntu server. UFW is a user-friendly interface to iptables, making firewall management much simpler.

## Prerequisites

UFW is typically installed by default on Ubuntu Server. If it's not, you can install it using:

```bash
sudo apt install ufw
```

## Ensuring IPv6 is Enabled

Modern Ubuntu versions have IPv6 enabled by default.  Verify this by checking the UFW configuration file:

```bash
sudo nano /etc/default/ufw
```

Ensure the `IPV6` value is set to `yes`:

```
IPV6=yes
```

Save and close the file (Ctrl+X, Y, Enter in nano).  UFW will now manage both IPv4 and IPv6 rules.

## Setting Default Policies

UFW's default policies control traffic that doesn't match specific rules.  A good starting point is to deny all incoming connections and allow all outgoing connections.

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
```

This enhances security by requiring explicit rules for incoming services.

## Allowing SSH Connections

Crucially, allow SSH connections before enabling UFW to avoid locking yourself out of your server.

### Using the OpenSSH Application Profile (Recommended)

UFW provides application profiles for common services. Check available profiles:

```bash
sudo ufw app list
```

Enable the OpenSSH profile:

```bash
sudo ufw allow OpenSSH
```

### Alternative Methods (Less Recommended)

You can also allow SSH by service name or port number, but the application profile is preferred:

```bash
sudo ufw allow ssh  # By service name
sudo ufw allow 22   # By port number
sudo ufw allow 2222 # If using a non-standard port (e.g., 2222)
```

## Enabling UFW

After configuring SSH access, enable UFW:

```bash
sudo ufw enable
```

You'll be prompted to confirm. Type `y` and press Enter.  Check the active rules:

```bash
sudo ufw status verbose
```

## Allowing Other Connections

Open other ports as needed.  Here are some examples:

* **HTTP (Port 80):** `sudo ufw allow http` or `sudo ufw allow 80`
* **HTTPS (Port 443):** `sudo ufw allow https` or `sudo ufw allow 443`
* **Apache Full:** `sudo ufw allow 'Apache Full'`
* **Nginx Full:** `sudo ufw allow 'Nginx Full'`

List available application profiles:

```bash
sudo ufw app list
```

### Specific Port Ranges

Allow port ranges (e.g., for X11):

```bash
sudo ufw allow 6000:6007/tcp
sudo ufw allow 6000:6007/udp  # Specify protocol
```

### Specific IP Addresses and Subnets

Allow connections from specific IP addresses:

```bash
sudo ufw allow from 203.0.113.4
sudo ufw allow from 203.0.113.4 to any port 22  # SSH from specific IP
```

Allow connections from a subnet (using CIDR notation):

```bash
sudo ufw allow from 203.0.113.0/24
sudo ufw allow from 203.0.113.0/24 to any port 22 # SSH from specific subnet
```

### Connections to a Specific Network Interface

Identify your network interfaces:

```bash
ip a
```

Allow HTTP traffic on `eth0`:

```bash
sudo ufw allow in on eth0 to any port 80
```

Allow MySQL on `eth1` (private network):

```bash
sudo ufw allow in on eth1 to any port 3306
```

## Denying Connections

While the default policy denies incoming connections, you can explicitly deny specific IPs or services:

```bash
sudo ufw deny http      # Deny HTTP
sudo ufw deny from 203.0.113.4 # Deny from specific IP
sudo ufw deny out to any port 25 # Deny outgoing SMTP
```

## Deleting Rules

### By Number (Less Recommended)

List rules with numbers:

```bash
sudo ufw status numbered
```

Delete rule number 2:

```bash
sudo ufw delete 2
```

### By Name (Recommended)

Delete by name:

```bash
sudo ufw delete allow http
sudo ufw delete 'Apache Full'
```

## Checking UFW Status

```bash
sudo ufw status
sudo ufw status verbose # For more details
```

## Disabling or Resetting UFW

Disable UFW:

```bash
sudo ufw disable
```

Reset UFW (removes all rules):

```bash
sudo ufw reset
```
