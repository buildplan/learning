#!/usr/bin/env python3
"""
Fail2Ban/NFTables Blocklist Importer (Pure Python Version)
Features: Parallel downloads, In-memory processing, Native NFTables integration.
"""

import os
import sys
import subprocess
import logging
import ipaddress
import urllib.request
import urllib.error
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

# --- CONFIGURATION ---
NFT_TABLE = "crowdsec_blocklists"
LOG_FILE = "/var/log/import-blocklists.log"
MIN_IPS = 200  # Safety brake threshold
MAX_WORKERS = 10  # How many downloads to run at once
TIMEOUT = 10  # Seconds per request
RETRIES = 3

# Custom Whitelist (IPs or CIDRs)
CUSTOM_WHITELIST = [
    "1.1.1.1",          # Cloudflare DNS
    "8.8.8.8",          # Google DNS
    "::1",              # Localhost
    "2001:4860:4860::8888",
    "2606:4700:4700::1111"
]

# Blocklist Sources (Name, URL, Type)
# Type 0 = Plain IP list
# Type 1 = DShield format (IP is 1st column, subnet is 3rd column) -> Handled generically by parsing
BLOCKLISTS = [
    ("AbuseIPDB", "https://raw.githubusercontent.com/borestad/blocklist-abuseipdb/main/abuseipdb-s100-30d.ipv4"),
    ("IPsum", "https://raw.githubusercontent.com/stamparm/ipsum/master/levels/3.txt"),
    ("Spamhaus DROP", "https://www.spamhaus.org/drop/drop.txt"),
    ("Emerging Threats", "https://rules.emergingthreats.net/blockrules/compromised-ips.txt"),
    ("Feodo Tracker", "https://feodotracker.abuse.ch/downloads/ipblocklist.txt"),
    ("URLhaus", "https://urlhaus.abuse.ch/downloads/text_online/"),
    ("CI Army", "https://cinsscore.com/list/ci-badguys.txt"),
    ("Binary Defense", "https://www.binarydefense.com/banlist.txt"),
    ("Tor Exit Nodes", "https://check.torproject.org/torbulkexitlist"),
    ("Blocklist.de", "https://lists.blocklist.de/lists/all.txt"),
    ("GreenSnow", "https://blocklist.greensnow.co/greensnow.txt"),
    ("DShield", "https://feeds.dshield.org/block.txt"),
    ("Spamhaus DROPv6", "https://www.spamhaus.org/drop/dropv6.txt"),
]

# --- SETUP LOGGING ---
logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] [%(levelname)s] %(message)s",
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler(sys.stdout)
    ]
)
log = logging.getLogger()

def fetch_url(name, url):
    """Downloads a URL with retries and returns the text content."""
    attempt = 0
    while attempt < RETRIES:
        try:
            req = urllib.request.Request(
                url,
                headers={'User-Agent': 'Blocklist-Updater/2.0 (Python)'}
            )
            with urllib.request.urlopen(req, timeout=TIMEOUT) as response:
                if response.status == 200:
                    return response.read().decode('utf-8', errors='ignore')
        except Exception as e:
            attempt += 1
            if attempt == RETRIES:
                log.warning(f"{name}: Failed after {RETRIES} retries. Error: {e}")
                return None
            time.sleep(1)
    return None

def parse_ips(text):
    """Extracts valid IP networks from text, ignoring comments."""
    valid_nets = []

    for line in text.splitlines():
        line = line.strip()
        # Remove comments
        if '#' in line: line = line.split('#', 1)[0]
        if ';' in line: line = line.split(';', 1)[0]
        line = line.strip()

        if not line: continue

        # DShield format (StartIP  EndIP  Netmask  Count)
        # try to grab the first token as the IP/Network
        parts = line.split()
        token = parts[0]

        try:
            # strict=False allows dirty bits (e.g. 1.2.3.1/24 -> 1.2.3.0/24)
            net = ipaddress.ip_network(token, strict=False)
            valid_nets.append(net)
        except ValueError:
            continue

    return valid_nets

def get_blocklists():
    """Downloads all blocklists in parallel."""
    v4_list = []
    v6_list = []

    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        future_to_name = {executor.submit(fetch_url, name, url): name for name, url in BLOCKLISTS}

        for future in as_completed(future_to_name):
            name = future_to_name[future]
            content = future.result()

            if content:
                nets = parse_ips(content)
                if not nets:
                    log.warning(f"{name}: Downloaded empty or invalid list.")
                    continue

                count = len(nets)
                log.info(f"{name}: Downloaded {count} entries.")

                for net in nets:
                    if isinstance(net, ipaddress.IPv4Network):
                        v4_list.append(net)
                    else:
                        v6_list.append(net)

    return v4_list, v6_list

def optimize_and_filter(networks, whitelist):
    """Removes whitelisted IPs and merges overlapping subnets."""
    # 1. Collapse overlaps (e.g. 1.1.1.1 + 1.1.1.2 -> 1.1.1.0/31)
    # This handles deduplication
    optimized = list(ipaddress.collapse_addresses(networks))

    # 2. Filter Whitelist (Check for overlaps)
    final_list = []
    whitelist_nets = [ipaddress.ip_network(w, strict=False) for w in whitelist]

    for net in optimized:
        whitelisted = False
        for wl in whitelist_nets:
            if net.overlaps(wl):
                whitelisted = True
                break
        if not whitelisted:
            final_list.append(net)

    return final_list

def apply_nftables(v4_nets, v6_nets):
    """Generates NFTables config and applies it."""

    # Convert list of network objects to comma-separated strings
    v4_str = ", ".join(str(n) for n in v4_nets)
    v6_str = ", ".join(str(n) for n in v6_nets)

    config = f"""
table inet {NFT_TABLE} {{
    set v4_list {{
        type ipv4_addr
        flags interval
        auto-merge
        elements = {{ {v4_str} }}
    }}

    set v6_list {{
        type ipv6_addr
        flags interval
        auto-merge
        elements = {{ {v6_str} }}
    }}

    chain inbound {{
        type filter hook input priority -100; policy accept;
        ip saddr @v4_list drop
        ip6 saddr @v6_list drop
    }}
}}
"""

    # Write to temp file
    nft_path = "/tmp/apply_blocklist.nft"
    with open(nft_path, "w") as f:
        f.write(config)

    # Validation Run
    chk = subprocess.run(["nft", "-c", "-f", nft_path], capture_output=True, text=True)
    if chk.returncode != 0:
        log.error("NFTables syntax check failed!")
        log.error(chk.stderr)
        return False

    # Apply
    # 1. Flush old table (ignore error if doesn't exist)
    subprocess.run(["nft", "delete", "table", "inet", NFT_TABLE], stderr=subprocess.DEVNULL)

    # 2. Load new rules
    apply = subprocess.run(["nft", "-f", nft_path], capture_output=True, text=True)

    if apply.returncode == 0:
        log.info(f"✓ Success! Blocked {len(v4_nets)} IPv4 and {len(v6_nets)} IPv6 networks.")
        return True
    else:
        log.error("Failed to apply NFTables rules.")
        log.error(apply.stderr)
        return False

def main():
    # File locking
    lock_file = "/tmp/import-blocklists.lock"
    if os.path.exists(lock_file):
        # Check if PID is still alive
        try:
            with open(lock_file, 'r') as f:
                pid = int(f.read().strip())
            os.kill(pid, 0)
            log.error(f"Script already running (PID {pid}). Exiting.")
            sys.exit(1)
        except (OSError, ValueError):
            log.warning("Stale lock file found. Removing.")
            os.remove(lock_file)

    with open(lock_file, 'w') as f:
        f.write(str(os.getpid()))

    try:
        log.info("Starting parallel download of blocklists...")

        # 1. Download
        v4_raw, v6_raw = get_blocklists()

        if not v4_raw and not v6_raw:
            log.error("No IPs downloaded. Check internet connection.")
            sys.exit(1)

        # 2. Optimize
        log.info("Optimizing lists (Merging and Whitelisting)...")
        v4_clean = optimize_and_filter(v4_raw, CUSTOM_WHITELIST)
        v6_clean = optimize_and_filter(v6_raw, CUSTOM_WHITELIST)

        # 3. Safety Check
        total_ips = len(v4_clean) + len(v6_clean)
        if total_ips < MIN_IPS:
            log.error(f"Safety Brake: Only found {total_ips} IPs (Threshold: {MIN_IPS}). Keeping old rules.")
            sys.exit(1)

        # 4. Apply
        apply_nftables(v4_clean, v6_clean)

    finally:
        if os.path.exists(lock_file):
            os.remove(lock_file)

if __name__ == "__main__":
    main()