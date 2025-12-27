**To allow a single user to run `apt update` and `apt upgrade` without a password:**

```bash
sudo visudo -f /etc/sudoers.d/99-nopasswd
```

**Add something like:**

```bash
Cmnd_Alias APT_CMDS    = /usr/bin/apt update, /usr/bin/apt upgrade, /usr/bin/apt autoremove
Cmnd_Alias BACKUP_CMDS = /home/user/scripts/backup/restic-backup.sh
Cmnd_Alias FW_CMDS     = /usr/sbin/ufw status, /usr/sbin/ufw status numbered, \
                         /usr/bin/fail2ban-client status, /usr/bin/fail2ban-client set, /usr/bin/fail2ban-client get
Cmnd_Alias ARCHIV_CMDS = /usr/bin/tar *
user ALL=(root) NOPASSWD: APT_CMDS, BACKUP_CMDS, FW_CMDS, ARCHIV_CMDS
```

**Fix the permissions:**

```bash
sudo chmod 0440 /etc/sudoers.d/99-nopasswd
```

**Check the config is valid:**

```bash
sudo visudo -c
```

* * *
