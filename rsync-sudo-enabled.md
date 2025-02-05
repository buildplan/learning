```markdown
# Creating a Remote User with Elevated Rsync Permissions

## Prerequisites

- **SSH Key-Based Authentication:** Ensure you have an SSH key pair and access to your remote server.
- **Sudo-Enabled User:** You’ll need a user with sudo privileges on the remote server to create and configure the new user.

---

## Steps

### 1. SSH to the Remote Server
```bash
ssh sudo_user@remote_host_ip_address
```
Replace `sudo_user` with your sudo-enabled user and `remote_host_ip_address` with the actual IP or hostname of your remote server.

### 2. Create a New User
```bash
sudo adduser rsyncuser
```
Follow the on-screen instructions to set a password for `rsyncuser`.

### 3. Grant Rsync Sudo Privileges
Edit the sudoers file:
```bash
sudo visudo
```
Add this line at the end:
```
rsyncuser ALL=(ALL) NOPASSWD: /usr/bin/rsync
```
This allows `rsyncuser` to execute `rsync` with sudo privileges **without a password**.

### 4. Set Up SSH Key-Based Authentication
Switch to the new user:
```bash
sudo -u rsyncuser -i
```
Create the `.ssh` directory:
```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
```
Add your public key:
```bash
echo "your_public_key" | tee -a ~/.ssh/authorized_keys > /dev/null
chmod 600 ~/.ssh/authorized_keys
chown -R rsyncuser:rsyncuser ~/.ssh
```
(Replace `your_public_key` with the actual content of your public SSH key.)

Ensure `rsync` is installed:
```bash
which rsync || sudo apt install -y rsync
```

---

## Using Rsync with the New User
Run the following command from your local machine to transfer files securely:
```bash
rsync -av -e ssh --rsync-path="sudo rsync" "/local/directory/" rsyncuser@remote_host_ip_address:"/remote/directory/"
```

**Replace:**
- `/local/directory/` → Your local directory path.
- `remote_host_ip_address` → Your remote server’s IP or hostname.
- `/remote/directory/` → Your desired remote directory path.

---

## Final Thoughts
✅ This method securely enables `rsyncuser` to perform privileged file transfers.  
✅ By restricting `sudo` permissions to only `rsync`, we improve security.  
✅ Proper SSH key and file permissions prevent unauthorized access issues.
```

