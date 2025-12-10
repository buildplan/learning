## Ignore IP addresses for fail2ban setup. 

Create `/etc/fail2ban/jail.local`

```ini
[DEFAULT]
# Local networks and Docker
ignoreip = 127.0.0.1/8 ::1 fe80::/10 172.80.0.0/16 172.16.0.0/12 10.0.0.0/8
# Tailscale ranges
           100.64.0.0/10 fd7a:115c:a1e0::/48
# Cloudflare IPv4
           173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22
           141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20
           197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13
           104.24.0.0/14 172.64.0.0/13 131.0.72.0/22
# Cloudflare IPv6
           2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32
           2405:8100::/32 2a06:98c0::/29 2c0f:f248::/32

bantime = 1d
findtime = 10m
maxretry = 5
banaction = ufw

# SSH port 
[sshd]
enabled = true
port = 5555

# This jail monitors UFW logs for rejected packets (port scans, etc.).
[ufw-probes]
enabled = true
port = all
filter = ufw-probes
logpath = /var/log/ufw.log
```

---

### For ufw-probes jail

create `/etc/fail2ban/filter.d/ufw-probes.conf`

```conf
[Definition]
# This regex looks for the standard "[UFW BLOCK]" message in /var/log/ufw.log
failregex = \[UFW BLOCK\] IN=.* OUT=.* SRC=<HOST>
ignoreregex =
```

---

### Useful Commands

| Task | Command |
| --- | --- |
| Check fail2ban service status | `sudo systemctl status fail2ban` |
| Start fail2ban | `sudo systemctl start fail2ban` |
| Restart fail2ban | `sudo systemctl restart fail2ban` |
| View all jail statuses | `sudo fail2ban-client status` |
| View a specific jail (e.g., sshd) | `sudo fail2ban-client status sshd` |
| See currently banned IPs in a jail | `sudo fail2ban-client get sshd banned` |
| Unban an IP from a jail | `sudo fail2ban-client set sshd unbanip <IP>` |
| Get ignore list for a jail | `sudo fail2ban-client get sshd ignoreip` |
| Manually test a filter (dry run) | `fail2ban-regex /var/log/auth.log /etc/fail2ban/filter.d/sshd.conf` |

### Filter & Jail File Paths

| File Purpose | Path |
| --- | --- |
| Jail configuration | `/etc/fail2ban/jail.local` |
| Custom filters | `/etc/fail2ban/filter.d/` |
| Fail2Ban main log | `/var/log/fail2ban.log` |
| UFW log (for ufw-block) | `/var/log/ufw.log` |

