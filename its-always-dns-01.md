## DNS Resolution Failure

### Initial Symptoms

- `curl: (6) Could not resolve host`
- Commands hang or timeout when trying to reach domains
- Server can ping IP addresses but not resolve hostnames

***

### Step 1: Identify the Problem

Run these diagnostic commands:

```bash
# Test if it's DNS-specific (bypass DNS with raw IP)
ping -c 3 1.1.1.1

# Test TCP connectivity
curl -v --connect-timeout 3 https://1.1.1.1

# Check DNS resolution
curl -v https://ip.me

# Check current DNS configuration
resolvectl status
cat /etc/resolv.conf
ls -la /etc/resolv.conf
```

**What to look for:**

- If `ping 1.1.1.1` works but `curl ip.me` fails → DNS problem
- If `/etc/resolv.conf` shows `nameserver 100.100.100.100` → Tailscale DNS issue
- If `/etc/resolv.conf` shows `nameserver 127.0.0.1` or `nameserver ::1` → No DNS server listening
- If `/etc/resolv.conf` shows `nameserver 127.0.0.53` → systemd-resolved stub issue
- If `/etc/resolv.conf` is a regular file (not a symlink) → Tailscale or another service is overwriting it

***

### Step 2: Test Which DNS Component is Broken

Use `host` command to test different resolvers:

```bash
# Test against a public DNS (should work)
host ip.me 1.1.1.1

# Test against Tailscale's Quad100 (may timeout)
host ip.me 100.100.100.100

# Test against systemd-resolved stub (may timeout)
host ip.me 127.0.0.53

# Test systemd-resolved via its API
resolvectl query google.com
```

**Diagnosis:**

- `host ip.me 1.1.1.1` works → External DNS works fine
- `host ip.me 100.100.100.100` times out → Tailscale DNS (Quad100) broken
- `host ip.me 127.0.0.53` times out → systemd-resolved stub broken
- `resolvectl query google.com` works but `curl` fails → Applications reading `/etc/resolv.conf` directly, not using systemd-resolved

***

### Step 3: Check What's Listening on Port 53

```bash
# Check what DNS servers are running
sudo ss -tlnup | grep ':53'

# Check systemd-resolved status
sudo systemctl status systemd-resolved --no-pager
```

**Expected output:**

- Should see `127.0.0.53` with `systemd-resolve` process
- If nothing listening on `:53`, systemd-resolved isn't running

***

### Step 4: Check Tailscale Status

```bash
tailscale status

# Look for health warnings like:
# "Tailscale failed to set the DNS configuration"
# "running /usr/sbin/resolvconf: Failed to resolve interface"
```

Check if Tailscale DNS is active:

```bash
resolvectl status | grep -A 8 tailscale0
```

Look for:

- `Current Scopes: DNS` (means Tailscale DNS is active)
- `DNS Servers: 100.100.100.100` (Tailscale's Quad100)
- `DNS Domain: ~.` (catch-all routing domain)

***

### Step 5: Choose Your Fix Strategy

Based on the diagnostics, choose the appropriate fix:

***

## FIX OPTION A: Disable Tailscale DNS (Most Reliable - Recommended for Servers)

**Use this if:**

- You don't need MagicDNS (resolving `hostname.ts.net` names)
- You want 100% reliable DNS
- Quad100 keeps timing out
- This is a production/server environment

```bash
# Disable Tailscale DNS
sudo tailscale set --accept-dns=false

# Point resolv.conf to systemd-resolved's direct upstream DNS file
sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf

# Restart and flush
sudo systemctl restart systemd-resolved
resolvectl flush-caches
```

**Verify:**

```bash
cat /etc/resolv.conf
# Should show real DNS servers (NOT 127.0.0.53, NOT 100.100.100.100)

curl -v ip.me
# Should work
```

**Pros:**

- Most reliable
- Uses your hosting provider's or custom DNS directly
- Won't break on reboots
- No stub listener issues

**Cons:**

- Lose MagicDNS (can't resolve `*.ts.net` hostnames)
- Must use Tailscale IPs (`100.x.x.x`) to reach devices

***

## FIX OPTION B: Fix systemd-resolved Stub + Keep MagicDNS

**Use this if:**

- You need MagicDNS to resolve Tailscale hostnames
- You're willing to troubleshoot if it breaks again
- Quad100 is actually working (test `host ip.me 100.100.100.100` succeeds)


### B1: Remove Conflicting Packages

```bash
# Check if resolvconf is installed
dpkg -l | egrep -i 'resolvconf|openresolv'

# If found, remove it
sudo apt purge -y resolvconf openresolv
```


### B2: Reset systemd-resolved Completely

```bash
# Stop services
sudo systemctl stop systemd-resolved tailscaled

# Clear all systemd-resolved state
sudo rm -rf /run/systemd/resolve/*

# Force stub symlink
sudo rm -f /etc/resolv.conf
sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# Start services in order
sudo systemctl start systemd-resolved
sudo systemctl start tailscaled

# Wait for Tailscale to configure DNS
sleep 5

# Flush and test
resolvectl flush-caches
resolvectl query google.com
```


### B3: Verify It Worked

```bash
# Check resolv.conf wasn't overwritten by Tailscale
ls -la /etc/resolv.conf
cat /etc/resolv.conf
# Should show: nameserver 127.0.0.53 (the stub)

# Check Tailscale DNS is active
resolvectl status | grep -A 8 tailscale0
# Should show: Current Scopes: DNS

# Check for health warnings
tailscale status | grep -i health

# Test actual resolution
curl -v ip.me
host your-hostname.mining-cliff.ts.net
```

**If curl still fails but resolvectl works:**
The stub is broken. Proceed to Option C or D.

***

## FIX OPTION C: Bypass Broken Stub + Keep MagicDNS

**Use this if:**

- Option B didn't work (stub times out)
- `resolvectl query` works but `curl` doesn't
- You want to keep MagicDNS but the stub at `127.0.0.53` is broken

```bash
# Stop services
sudo systemctl stop systemd-resolved tailscaled

# Use DIRECT DNS file (bypasses stub)
sudo rm -f /etc/resolv.conf
sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf

# Start services
sudo systemctl start systemd-resolved
sudo systemctl start tailscaled

# Wait and test
sleep 5
cat /etc/resolv.conf
# Should show real DNS servers, NOT 127.0.0.53

curl -v ip.me
```

**If Tailscale overwrites resolv.conf again** (shows `100.100.100.100`):
Proceed to Option D.

***

## FIX OPTION D: Lock resolv.conf to Prevent Tailscale Overwriting

**Use this if:**

- Tailscale keeps overwriting `/etc/resolv.conf` despite symlinks
- You've tried Option C but Tailscale replaces the symlink with its own file
- You want to force working DNS regardless of what Tailscale tries


### D1: Make resolv.conf Immutable

```bash
# Stop services
sudo systemctl stop tailscaled systemd-resolved

# Force correct symlink to direct DNS
sudo rm -f /etc/resolv.conf
sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf

# Make it immutable (cannot be deleted/modified even by root)
sudo chattr +i /etc/resolv.conf

# Start services
sudo systemctl start systemd-resolved
sudo systemctl start tailscaled

# Test after 5 seconds
sleep 5
ls -la /etc/resolv.conf
# Should still be a symlink, not overwritten

cat /etc/resolv.conf
# Should show real DNS servers

curl -v ip.me
```

**Check Tailscale status:**

```bash
tailscale status
# May show health warning about unable to set DNS (expected and harmless)
```

**To remove immutable flag later** (if needed):

```bash
sudo chattr -i /etc/resolv.conf
```

**Pros:**

- Guarantees DNS works regardless of Tailscale behavior
- systemd-resolved can still manage DNS dynamically
- Survives reboots

**Cons:**

- Tailscale will complain it can't set DNS (health warning)
- You must remove immutable flag if you want to change DNS manually later

***

## FIX OPTION E: Emergency Bypass (Temporary - Not Persistent)

**Use this for:**

- Immediate DNS access while you troubleshoot
- Testing if the problem is systemd-resolved vs Tailscale
- Not recommended for permanent use

```bash
sudo rm -f /etc/resolv.conf
sudo tee /etc/resolv.conf >/dev/null <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

curl -v ip.me
```

**Warning:** This will be overwritten by Tailscale or network manager on next restart/network change.

***

## Step 6: Set Custom DNS Servers (Optional)

If you want to use specific DNS providers (Cloudflare, Quad9, etc.) instead of your hosting provider's DNS:

```bash
sudo mkdir -p /etc/systemd/resolved.conf.d/
sudo nano /etc/systemd/resolved.conf.d/dns_servers.conf
```

**Choose a configuration:**

**Cloudflare Primary + Quad9 Backup:**

```ini
[Resolve]
DNS=1.1.1.1 9.9.9.9
FallbackDNS=8.8.8.8 149.112.112.112
```

**Cloudflare Only:**

```ini
[Resolve]
DNS=1.1.1.1 1.0.0.1
FallbackDNS=8.8.8.8 8.8.4.4
```

**Quad9 Only (blocks malware):**

```ini
[Resolve]
DNS=9.9.9.9 149.112.112.112
FallbackDNS=1.1.1.1 1.0.0.1
```

Save (Ctrl+O, Enter, Ctrl+X), then apply:

```bash
sudo systemctl restart systemd-resolved
resolvectl flush-caches
cat /etc/resolv.conf
```

**To remove custom DNS:**

```bash
sudo rm /etc/systemd/resolved.conf.d/dns_servers.conf
sudo systemctl restart systemd-resolved
```


***

## Step 7: Verification Checklist

After applying any fix, verify everything works:

```bash
# 1. Check resolv.conf is correct
cat /etc/resolv.conf
ls -la /etc/resolv.conf

# 2. Check systemd-resolved status
sudo systemctl status systemd-resolved --no-pager

# 3. Test DNS resolution multiple ways
resolvectl query google.com
host ip.me
curl -v ip.me

# 4. Check Tailscale health
tailscale status

# 5. Verify DNS servers being used
resolvectl status | head -30

# 6. Check what's listening on port 53
sudo ss -tlnup | grep ':53'
```

**Expected results:**

- `curl ip.me` returns your public IP successfully
- `systemd-resolved` is `active (running)`
- No "connection refused" or "timed out" errors
- `/etc/resolv.conf` is a symlink (not a regular file, unless using Option D with immutable)

***

## Common Issues and Solutions

### Issue: "communications error to 127.0.0.53\#53: timed out"

**Cause:** systemd-resolved stub is broken

**Fix:** Use Option A or C (bypass the stub)

***

### Issue: "Could not resolve host" but `resolvectl query` works

**Cause:** Applications reading `/etc/resolv.conf` directly, which points to broken DNS

**Fix:** Check what `/etc/resolv.conf` points to:

```bash
cat /etc/resolv.conf
```

- If shows `100.100.100.100` → Use Option A (disable Tailscale DNS)
- If shows `127.0.0.53` and times out → Use Option C (bypass stub)

***

### Issue: Tailscale health warning "Failed to resolve interface 'tailscale'"

**Cause:** `resolvconf` package conflict

**Fix:**

```bash
sudo apt purge -y resolvconf openresolv
sudo systemctl restart tailscaled
```


***

### Issue: DNS works after reboot but breaks later

**Cause:** Tailscale re-enabling DNS or systemd-resolved stub breaking

**Fix:** Use Option A (most reliable) or Option D (lock the file)

***

### Issue: Tailscale keeps overwriting /etc/resolv.conf

**Cause:** Tailscale doesn't detect systemd-resolved, overwrites file directly

**Fix:**

```bash
# Check resolv.conf mode
resolvectl status | grep "resolv.conf mode"
```

- If shows `foreign` → Tailscale thinks it owns DNS
- Use Option D (make immutable) or Option A (disable Tailscale DNS)

***

### Issue: "communications error to ::1\#53: connection refused" or "127.0.0.1\#53: connection refused"

**Cause:** No DNS server listening on localhost

**Fix:** systemd-resolved isn't running or configured wrong:

```bash
sudo systemctl start systemd-resolved
sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
sudo systemctl restart systemd-resolved
```


***

## Quick Reference: One-Line Fixes

**Fast reliable fix (disable Tailscale DNS):**

```bash
sudo tailscale set --accept-dns=false
sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
sudo systemctl restart systemd-resolved
resolvectl flush-caches
curl -v ip.me
```

**Emergency bypass (temporary):**

```bash
sudo tee /etc/resolv.conf >/dev/null <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
```

**Reset systemd-resolved completely:**

```bash
sudo systemctl stop systemd-resolved
sudo rm -rf /run/systemd/resolve/*
sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
sudo systemctl start systemd-resolved
resolvectl flush-caches
```

**Lock resolv.conf to prevent overwriting:**

```bash
sudo chattr +i /etc/resolv.conf
```

**Unlock resolv.conf:**

```bash
sudo chattr -i /etc/resolv.conf
```


***

## Understanding the Files

- `/etc/resolv.conf` → What applications read for DNS servers
- `/run/systemd/resolve/stub-resolv.conf` → Points to `127.0.0.53` (systemd-resolved stub listener)
- `/run/systemd/resolve/resolv.conf` → Contains actual upstream DNS servers (bypasses stub)
- `/etc/systemd/resolved.conf.d/*.conf` → Custom DNS server configuration
- `100.100.100.100` (Quad100) → Tailscale's device-local DNS service for MagicDNS

***

## Decision Tree: Which Fix Should I Use?

```text
Do you need MagicDNS (*.ts.net resolution)?
│
├─ NO → Use Option A (disable Tailscale DNS)
│        ✓ Most reliable
│        ✓ Simplest
│        ✓ Works on all systems
│
└─ YES → Test: host ip.me 100.100.100.100
         │
         ├─ Times out → Quad100 is broken
         │             Use Option A anyway
         │             (MagicDNS won't work)
         │
         └─ Works → Test: host ip.me 127.0.0.53
                    │
                    ├─ Times out → Stub is broken
                    │             Try Option C (bypass stub)
                    │             If Tailscale overwrites → Option D (lock file)
                    │
                    └─ Works → Try Option B (reset systemd-resolved)
                               If still fails → Option C or D
```

***

## When to Use Each Option

### Option A (Disable Tailscale DNS)

- **Best for:** Production servers, VPS, Docker hosts
- **Reliability:** ★★★★★
- **Complexity:** ★☆☆☆☆
- **MagicDNS:** ✗ No

### Option B (Fix Stub + MagicDNS)

- **Best for:** Workstations, dev machines where you use Tailscale names
- **Reliability:** ★★★☆☆
- **Complexity:** ★★★☆☆
- **MagicDNS:** ✓ Yes

### Option C (Bypass Stub + MagicDNS)

- **Best for:** Systems where stub is broken but Quad100 works
- **Reliability:** ★★★★☆
- **Complexity:** ★★☆☆☆
- **MagicDNS:** ✓ Yes (if Tailscale doesn't overwrite)

### Option D (Lock File)

- **Best for:** Systems where Tailscale aggressively overwrites resolv.conf
- **Reliability:** ★★★★★
- **Complexity:** ★★★☆☆
- **MagicDNS:** ✗ No (Tailscale can't configure it)

### Option E (Emergency Bypass)

- **Best for:** Temporary quick fix while troubleshooting
- **Reliability:** ★★☆☆☆
- **Complexity:** ★☆☆☆☆
- **MagicDNS:** ✗ No

***

## Troubleshooting After Fix

If DNS still doesn't work after applying a fix:

### Check for firewall blocking localhost DNS

```bash
sudo iptables -L -n -v | grep 53
sudo nft list ruleset | grep 53
```

### Check journalctl for errors

```bash
sudo journalctl -u systemd-resolved --since "10 min ago" | tail -50
sudo journalctl -u tailscaled --since "10 min ago" | grep -i dns
```

### Verify network connectivity

```bash
ping -c 3 1.1.1.1
traceroute -n 1.1.1.1
```

### Check if Docker is interfering

```bash
docker network ls
# Docker can create conflicting DNS on 127.0.0.11
```
