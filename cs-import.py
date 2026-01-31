#!/usr/bin/env python3
"""
2026-01-31
CrowdSec Blocklist Importer (Python Version)
Auto-detect Native/Docker.
"""

import os
import sys
import subprocess
import logging
import ipaddress
import urllib.request
import urllib.error
import time
import re
import json
import tempfile
from concurrent.futures import ThreadPoolExecutor, as_completed

# --- ROOT CHECK ---
if os.geteuid() != 0:
    print("Error: This script must be run as root (use sudo).", file=sys.stderr)
    sys.exit(1)

# --- CONFIGURATION ---
LOG_FILE = "/var/log/cs-import.log"
MIN_IPS = 200            # Safety brake
MAX_WORKERS = 10         # Parallel downloads
TIMEOUT = 15             # Seconds per request
RETRIES = 3
DECISION_DURATION = "24h"
CROWDSEC_CONTAINER = "crowdsec" # Name of container if using Docker

# Custom Whitelist (IPs or CIDRs)
CUSTOM_WHITELIST = [
    "1.1.1.1", "8.8.8.8", "::1",
    "2001:4860:4860::8888", "2606:4700:4700::1111"
]

# Blocklist Sources
BLOCKLISTS = [
    ("AbuseIPDB", "https://raw.githubusercontent.com/borestad/blocklist-abuseipdb/main/abuseipdb-s100-30d.ipv4"),
    ("IPsum", "https://raw.githubusercontent.com/stamparm/ipsum/master/levels/3.txt"),
    ("Spamhaus DROP", "https://www.spamhaus.org/drop/drop.txt"),
    ("Spamhaus EDROP", "https://raw.githubusercontent.com/firehol/blocklist-ipsets/refs/heads/master/spamhaus_edrop.netset"),
    ("Emerging Threats", "https://rules.emergingthreats.net/blockrules/compromised-ips.txt"),
    ("Feodo Tracker", "https://feodotracker.abuse.ch/downloads/ipblocklist.txt"),
    ("URLhaus", "https://urlhaus.abuse.ch/downloads/text_online/"),
    ("CI Army", "https://cinsscore.com/list/ci-badguys.txt"),
    ("Clean talk", "https://raw.githubusercontent.com/firehol/blocklist-ipsets/refs/heads/master/cleantalk_1d.ipset"),
    ("Binary Defense", "https://www.binarydefense.com/banlist.txt"),
    ("Bruteforce Blocker", "https://danger.rulez.sk/projects/bruteforceblocker/blist.php"),
    ("Tor Exit Nodes", "https://check.torproject.org/torbulkexitlist"),
    ("Blocklist.de All", "https://lists.blocklist.de/lists/all.txt"),
    ("Blocklist.de SSH", "https://lists.blocklist.de/lists/ssh.txt"),
    ("Blocklist.de Apache", "https://lists.blocklist.de/lists/apache.txt"),
    ("Blocklist.de Mail", "https://lists.blocklist.de/lists/mail.txt"),
    ("GreenSnow", "https://blocklist.greensnow.co/greensnow.txt"),
    ("DShield", "https://feeds.dshield.org/block.txt"),
    ("Botscout", "https://raw.githubusercontent.com/firehol/blocklist-ipsets/refs/heads/master/botscout_7d.ipset"),
    ("Firehol L1", "https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/firehol_level1.netset"),
    ("Firehol L2", "https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/firehol_level2.netset"),
    ("Firehol L3", "https://raw.githubusercontent.com/firehol/blocklist-ipsets/refs/heads/master/firehol_level3.netset"),
    ("Firehol Webclient", "https://raw.githubusercontent.com/firehol/blocklist-ipsets/refs/heads/master/firehol_webclient.netset"),
    ("MyIP.ms", "https://raw.githubusercontent.com/firehol/blocklist-ipsets/refs/heads/master/myip.ipset"),
    ("SOCKS Proxies", "https://raw.githubusercontent.com/firehol/blocklist-ipsets/refs/heads/master/socks_proxy_7d.ipset"),
    ("Botvrij", "https://www.botvrij.eu/data/ioclist.ip-dst.raw"),
    ("StopForumSpam", "https://www.stopforumspam.com/downloads/toxic_ip_cidr.txt"),
    ("Shodan Scanners", "https://gist.githubusercontent.com/jfqd/4ff7fa70950626a11832a4bc39451c1c/raw"),
    ("PHP Spammers", "https://raw.githubusercontent.com/firehol/blocklist-ipsets/refs/heads/master/php_spammers_7d.ipset"),
    ("Spamhaus DROPv6", "https://www.spamhaus.org/drop/dropv6.txt"),
]

# --- LOGGING SETUP ---
logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] [%(levelname)s] %(message)s",
    handlers=[logging.FileHandler(LOG_FILE), logging.StreamHandler(sys.stdout)]
)
log = logging.getLogger()

# --- HELPER FUNCTIONS ---

def fetch_url(name, url):
    attempt = 0
    while attempt < RETRIES:
        try:
            req = urllib.request.Request(url, headers={'User-Agent': 'Blocklist-Updater/2.0 (Python)'})
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

def is_safe_ip(net):
    if net.is_private or net.is_loopback or net.is_link_local or net.is_multicast or net.is_reserved:
        return False
    if isinstance(net, ipaddress.IPv4Network) and str(net).startswith('0.'):
        return False
    return True

def parse_ips(name, text):
    valid_nets = set()
    ipv4_pattern = re.compile(r'\b(?:\d{1,3}\.){3}\d{1,3}\b')

    for line in text.splitlines():
        line = line.strip()
        if '#' in line: line = line.split('#', 1)[0]
        if ';' in line: line = line.split(';', 1)[0]
        line = line.strip()
        if not line: continue

        net = None
        # 1. DShield Handling
        if name == "DShield":
            parts = line.split()
            if len(parts) >= 3 and parts[2].isdigit():
                try:
                    prefix = int(parts[2])
                    if 0 <= prefix <= 32:
                        net = ipaddress.ip_network(f"{parts[0]}/{prefix}", strict=False)
                except ValueError: pass

        # 2. Standard Parsing
        if net is None:
            try:
                token = line.split()[0]
                net = ipaddress.ip_network(token, strict=False)
            except ValueError:
                match = ipv4_pattern.search(line)
                if match:
                    try:
                        net = ipaddress.ip_network(match.group(), strict=False)
                    except ValueError: pass

        if net and is_safe_ip(net):
            valid_nets.add(net)

    return valid_nets

def get_blocklists():
    all_nets = []
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        future_to_name = {executor.submit(fetch_url, name, url): name for name, url in BLOCKLISTS}
        for future in as_completed(future_to_name):
            name = future_to_name[future]
            content = future.result()
            if content:
                nets = parse_ips(name, content)
                if nets:
                    log.info(f"{name}: Downloaded {len(nets)} entries.")
                    all_nets.extend(nets)
                else:
                    log.warning(f"{name}: Empty or invalid list.")
    return all_nets

def optimize_and_filter(networks, whitelist):
    v4_nets = [n for n in networks if n.version == 4]
    v6_nets = [n for n in networks if n.version == 6]
    whitelist_v4 = [ipaddress.ip_network(w, strict=False) for w in whitelist if ipaddress.ip_network(w, strict=False).version == 4]
    whitelist_v6 = [ipaddress.ip_network(w, strict=False) for w in whitelist if ipaddress.ip_network(w, strict=False).version == 6]
    def process_list(nets, wl_nets):
        if not nets: return []
        nets = list(ipaddress.collapse_addresses(nets))
        results = []
        for net in nets:
            candidates = [net]
            for wl in wl_nets:
                new_candidates = []
                for candidate in candidates:
                    if not candidate.overlaps(wl):
                        new_candidates.append(candidate)
                        continue
                    if wl.supernet_of(candidate) or wl == candidate:
                        continue
                    try:
                        subnets = list(candidate.address_exclude(wl))
                        new_candidates.extend(subnets)
                    except ValueError: pass
                candidates = new_candidates
                if not candidates: break
            results.extend(candidates)
        return list(ipaddress.collapse_addresses(results))
    final_v4 = process_list(v4_nets, whitelist_v4)
    final_v6 = process_list(v6_nets, whitelist_v6)
    return final_v4 + final_v6

# --- CROWDSEC SPECIFIC LOGIC ---

def detect_mode():
    """Detects if we should run native cscli or docker exec."""
    # Try Native
    try:
        subprocess.run(["cscli", "version"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        log.info("Mode: Native (cscli found)")
        return "native"
    except (FileNotFoundError, subprocess.CalledProcessError):
        pass

    # Try Docker
    try:
        res = subprocess.run(["docker", "ps", "-q", "-f", f"name=^{CROWDSEC_CONTAINER}$"], capture_output=True, text=True)
        if res.stdout.strip():
            log.info(f"Mode: Docker (container: {CROWDSEC_CONTAINER})")
            return "docker"
    except FileNotFoundError:
        pass

    log.error("Could not detect CrowdSec (neither 'cscli' nor Docker container found).")
    sys.exit(1)

def get_existing_decisions(mode):
    """Fetches current bans from CrowdSec to avoid duplicates."""
    cmd = []
    if mode == "native":
        cmd = ["cscli", "decisions", "list", "-a", "-o", "json"]
    else:
        cmd = ["docker", "exec", CROWDSEC_CONTAINER, "cscli", "decisions", "list", "-a", "-o", "json"]

    log.info("Fetching existing decisions from CrowdSec...")
    try:
        res = subprocess.run(cmd, capture_output=True, text=True)
        if res.returncode != 0:
            log.warning("Failed to fetch existing decisions (this is normal on first run).")
            return set()

        # If output is empty or "null", return empty set
        if not res.stdout.strip() or res.stdout.strip() == "null":
            return set()

        data = json.loads(res.stdout)
        existing_ips = set()
        for item in data:
            if "value" in item:
                existing_ips.add(item["value"])

        log.info(f"Found {len(existing_ips)} existing bans in DB.")
        return existing_ips
    except json.JSONDecodeError:
        log.warning("Could not parse cscli output as JSON. Assuming empty.")
        return set()

def import_decisions(mode, new_nets):
    """Imports the new IPs into CrowdSec."""
    if not new_nets:
        log.info("No new IPs to import.")
        return

    import_data = "\n".join(str(net) for net in new_nets)

    base_cmd = ["decisions", "import", "-i", "-"]

    # CrowdSec Flag
    flags = [
        "--format", "values",
        "--duration", DECISION_DURATION,
        "--reason", "external_blocklist",
        "--type", "ban"
    ]

    if mode == "native":
        cmd = ["cscli"] + base_cmd + flags
    else:
        cmd = ["docker", "exec", "-i", CROWDSEC_CONTAINER, "cscli"] + base_cmd + flags

    log.info(f"Importing {len(new_nets)} new decisions...")

    try:
        res = subprocess.run(cmd, input=import_data, text=True, capture_output=True)
        if res.returncode == 0:
            log.info("✓ Import successful.")
        else:
            log.error("Import failed.")
            log.error(res.stderr)
    except Exception as e:
        log.error(f"Error during import: {e}")

# --- MAIN ---

def main():
    # File locking
    lock_file = "/tmp/cs-import.lock"
    if os.path.exists(lock_file):
        try:
            with open(lock_file, 'r') as f:
                os.kill(int(f.read().strip()), 0)
            log.error("Script already running. Exiting.")
            sys.exit(1)
        except:
            os.remove(lock_file)
    with open(lock_file, 'w') as f: f.write(str(os.getpid()))

    try:
        mode = detect_mode()

        log.info("Starting blocklist download...")
        raw_nets = get_blocklists()

        if not raw_nets:
            log.error("No IPs downloaded. Exiting.")
            sys.exit(1)

        log.info("Optimizing and cleaning lists...")
        clean_nets = optimize_and_filter(raw_nets, CUSTOM_WHITELIST)

        total_ips = len(clean_nets)
        if total_ips < MIN_IPS:
            log.error(f"Safety Brake: Only found {total_ips} IPs. Aborting.")
            sys.exit(1)

        # Deduplication
        existing = get_existing_decisions(mode)

        # Convert objects to strings for comparison
        clean_nets_str = {str(n) for n in clean_nets}

        # Subtract existing from new
        new_to_import_str = clean_nets_str - existing

        log.info(f"Total List: {len(clean_nets_str)} | Existing: {len(existing)} | New to Import: {len(new_to_import_str)}")

        if new_to_import_str:
            import_decisions(mode, new_to_import_str)
        else:
            log.info("Database is already up to date.")

    finally:
        if os.path.exists(lock_file): os.remove(lock_file)

if __name__ == "__main__":
    main()