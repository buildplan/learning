## Setting up Docker Credential Helper (`pass` + GPG) on Linux

---

**Goal:** Securely store `docker login` credentials using GPG encryption via the `pass` password manager, eliminating the insecure storage warning in `~/.docker/config.json`.

**Prerequisites:**
* Linux system (Debian/Ubuntu commands shown)
* Docker installed
* User with `sudo` privileges

**Steps:**

**1. Install Prerequisites**

Install `pass`, `gnupg2`, and `rng-tools` (for server entropy):
```bash
sudo apt update && sudo apt install pass gnupg2 rng-tools -y
```

**2. Ensure Sufficient Entropy (Servers)**

Help speed up key generation:
```bash
sudo rngd -r /dev/urandom
```

**3. Generate GPG Key (if needed)**

If you don't already have a suitable GPG key, generate one:
```bash
gpg --full-generate-key
```
Follow the prompts:
* **Key type:** Choose `(1) RSA and RSA`.
* **Key size:** `4096`.
* **Expiration:** `1y` or `0` (your preference).
* **User ID:** Enter your Real name, Email address.
* **Passphrase:** Create and confirm a **strong passphrase**. **Remember this!**

**4. Get Your GPG Key ID**

Identify the long ID of the key you will use:
```bash
gpg --list-secret-keys --keyid-format=long
```
Look for the `sec` line. Copy the **long hex string** after the `/` (e.g., `ABCDEF0123456789...`).

**5. Initialize `pass` Password Store**

Tell `pass` which GPG key to use. Replace `<Your-GPG-Key-ID>`:
```bash
pass init <Your-GPG-Key-ID>
```
*(Example: `pass init ABCDEF0123456789...`)*

**6. Install `docker-credential-pass` Helper**

Download the helper binary and place it in your PATH:
```bash
# Check for the absolute latest version if desired:
# https://github.com/docker/docker-credential-helpers/releases
VERSION="v0.8.2" # Use a known recent version
ARCH="amd64"   # Assuming amd64 architecture

URL="https://github.com/docker/docker-credential-helpers/releases/download/${VERSION}/docker-credential-pass-${VERSION}.linux-${ARCH}"

echo "Downloading docker-credential-pass ${VERSION}..."
wget -O docker-credential-pass "${URL}"

echo "Making executable and moving to /usr/local/bin..."
chmod +x docker-credential-pass
sudo mv docker-credential-pass /usr/local/bin/

echo "Verifying installation..."
docker-credential-pass version
```

**7. Configure Docker to Use `pass`**

Edit (or create) Docker's config file:
```bash
mkdir -p ~/.docker
nano ~/.docker/config.json
```
Ensure the file contains *at least* the following top-level key:
```json
{
  "credsStore": "pass"
}
```
*(If the file already exists with an `auths` section, add `"credsStore": "pass",` ensuring correct JSON comma placement).*
Save and close the file.

**8. Test Login & Store Credentials**

Log in to your registries. Docker should now use the helper.

```bash
# Example for your private registry
docker logout registry.alisufyan.cloud # Optional clear first
docker login registry.alisufyan.cloud -u alis
# Enter password for alis

# Example for Docker Hub
docker logout docker.io
docker login docker.io
# Enter Docker Hub username and password/token
```
* **Expect:** You should **not** see the insecure storage warning. You **should** be prompted for your **GPG passphrase** (the one from Step 3) the first time `pass` needs to access the store after the `gpg-agent` cache expires. Subsequent logins might not prompt if the cache is still active. Logins should succeed.

---

**Troubleshooting Tip (If "No secret key" error occurs later):**

If `docker login` or other Docker commands fail with `gpg: decryption failed: No secret key`, try these steps:

1.  **Check GPG TTY:** Ensure GPG knows your terminal: `export GPG_TTY=$(tty)` (add to `.bashrc` for persistence: `echo 'export GPG_TTY=$(tty)' >> ~/.bashrc && source ~/.bashrc`). Then run `gpg-connect-agent updatestartuptty /bye`.
2.  **Restart Agent:** Force kill the agent: `gpgconf --kill gpg-agent`. Wait a few seconds.
3.  **Test `pass`:** Manually decrypt a stored credential using `pass show <path_from_pass_ls>`. Enter GPG passphrase when prompted.
4.  **Retry Docker:** Immediately retry the failing Docker command.

This should serve as a good reference for setting up and troubleshooting the credential helper on your Linux systems.
