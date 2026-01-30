#!/bin/bash
#
# 2026-01-30
# Fail2Ban/NFTables Blocklist Importer (IPv4 + IPv6)
# Fetches multiple public blocklists, validates IPs/CIDRs, applies whitelisting, and updates NFTables sets.
# For use with Fail2Ban to block malicious IPs at the firewall level.
# Works on systems with NFTables (Debian 12/13).
# Usage:
#   - Save this script as /usr/local/bin/import-blocklists.sh
#   - Make it executable: chmod +x /usr/local/bin/import-blocklists.sh
#   - Schedule via cron or systemd timer for periodic updates.
# cron: 0 4 * * * /usr/local/bin/import-blocklists.sh >> /var/log/import-blocklists.log 2>&1
# @reboot sleep 30 && /usr/local/bin/import-blocklists.sh >> /var/log/import-blocklists.log 2>&1
# Requirements:
#   - curl
#   - nftables
#   - python3
# Note: Adjust CUSTOM_WHITELIST variable to add your own whitelisted IPs or prefixes.
# Setup log rotation for /var/log/import-blocklists.log as needed.

set -euo pipefail
IFS=$'\n\t'

# --- CONFIGURATION ---
NFT_TABLE="crowdsec_blocklists"
CURL_TIMEOUT=45
CURL_RETRIES=3
LOG_FILE="/var/log/import-blocklists.log"
MIN_IPS=200  # Minimum total IPs (v4 + v6) required to apply new rules

# CUSTOM WHITELIST
# Add IPs (1.2.3.4) or Prefixes (2b01:...) here.
CUSTOM_WHITELIST=""

# --- INITIALIZATION ---
# Redirect all output to log file
exec > >(tee -a "$LOG_FILE") 2>&1

# Check for required commands
for cmd in curl awk grep nft python3; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "[ERROR] Required command '$cmd' not found. Please install it."
        exit 1
    fi
done

# Create temporary working directory and lock file
TEMP_DIR=$(mktemp -d -t nft-blocklist.XXXXXXXXXX)
LOCK_FILE="/tmp/nft-blocklist-import.lock"

cleanup() {
    rm -rf "$TEMP_DIR"
    rm -f "$LOCK_FILE"
}
trap cleanup EXIT

# Prevent concurrent runs
if [ -f "$LOCK_FILE" ]; then
    if kill -0 "$(cat "$LOCK_FILE")" 2>/dev/null; then
        echo "[ERROR] Script is already running (PID $(cat "$LOCK_FILE")). Exiting."
        exit 1
    else
        echo "[WARN] Stale lock found. Removing."
    fi
fi
echo $$ > "$LOCK_FILE"

log()   { echo "[$(date +'%Y-%m-%d %H:%M:%S')] [INFO]  $*"; }
warn()  { echo "[$(date +'%Y-%m-%d %H:%M:%S')] [WARN]  $*"; }
error() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] $*"; }

# --- CORE FUNCTIONS ---
fetch_list() {
    local name="$1"
    local url="$2"
    local output="$3"
    local filter="${4:-cat}"

    log "Fetching $name..."

    set +e
    local http_code; http_code=$(curl -sS -w "%{http_code}" -o /tmp/curl_tmp.$$ \
        -A "Blocklist-Updater/1.0 (nftables)" \
        --retry "$CURL_RETRIES" --retry-delay 2 --max-time "$CURL_TIMEOUT" \
        "$url" 2>&1 | tail -n1)

    local ret=$?

    if [ "$ret" -eq 0 ] && [ "$http_code" = "200" ] && [ -s /tmp/curl_tmp.$$ ]; then
        cat /tmp/curl_tmp.$$ | eval "$filter" > "$output"
        rm -f /tmp/curl_tmp.$$

        if [ -s "$output" ]; then
            log "$name: ✓ Success ($(wc -l < "$output") entries)"
            set -e
            return 0
        else
            warn "$name: Filtered to 0 entries (ignoring)"
            rm -f "$output"
            set -e
            return 1
        fi
    else
        warn "$name: Failed (HTTP $http_code, exit $ret)"
        rm -f /tmp/curl_tmp.$$ "$output"
        set -e
        return 1
    fi
}

# Strict IPv4 validation - rejects leading zeros and invalid formats
validate_ipv4() {
    python3 -c "
import sys, ipaddress
valid_count = 0
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        # Split IP and CIDR if present
        if '/' in line:
            ip_part, cidr = line.split('/', 1)
            cidr = int(cidr)
            if not (0 <= cidr <= 32):
                continue
        else:
            ip_part = line

        # Reject leading zeros (e.g., 1.0.7.01)
        octets = ip_part.split('.')
        if len(octets) != 4:
            continue

        # Check for leading zeros or invalid octets
        for octet in octets:
            if not octet or not octet.isdigit():
                raise ValueError('Invalid octet')
            # Reject leading zeros like '01', '001' (but allow '0')
            if len(octet) > 1 and octet[0] == '0':
                raise ValueError('Leading zero')
            if int(octet) > 255:
                raise ValueError('Octet > 255')

        # Validate with ipaddress module
        net = ipaddress.ip_network(line, strict=False)
        if isinstance(net, ipaddress.IPv4Network):
            print(net)
            valid_count += 1
    except (ValueError, ipaddress.AddressValueError):
        continue
sys.exit(0 if valid_count > 0 else 1)
"
}

# Strict IPv6 validation
validate_ipv6() {
    python3 -c "
import sys, ipaddress
valid_count = 0
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        net = ipaddress.ip_network(line, strict=False)
        if isinstance(net, ipaddress.IPv6Network):
            print(net)
            valid_count += 1
    except (ValueError, ipaddress.AddressValueError):
        continue
sys.exit(0 if valid_count > 0 else 1)
"
}

optimize_list() {
    python3 -c "
import sys, ipaddress
nets = []
invalid_count = 0

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        net = ipaddress.ip_network(line, strict=False)
        nets.append(net)
    except Exception as e:
        invalid_count += 1
        sys.stderr.write(f'Skipping invalid: {line} ({e})\n')

if invalid_count > 0:
    sys.stderr.write(f'Skipped {invalid_count} invalid entries\n')

if not nets:
    sys.stderr.write('No valid networks to optimize\n')
    sys.exit(1)

for net in ipaddress.collapse_addresses(nets):
    print(net)
"
}

apply_whitelist() {
    local input_file="$1"
    local output_file="$2"

    python3 -c "
import sys, ipaddress

whitelist = []
with open('whitelist_patterns.txt') as f:
    for line in f:
        line = line.strip()
        if line:
            try:
                whitelist.append(ipaddress.ip_network(line, strict=False))
            except:
                pass

with open('$input_file') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            ip = ipaddress.ip_network(line, strict=False)
            if not any(ip.overlaps(wl) for wl in whitelist):
                print(line)
        except:
            pass
" > "$output_file"
}

# --- MAIN ---

main() {
    cd "$TEMP_DIR"

    FETCH_SUCCESS_COUNT=0
    FETCH_TOTAL=0

    # Fetching IPv4 Lists (continue on individual failures)
    FETCH_TOTAL=$((FETCH_TOTAL + 1)); fetch_list "AbuseIPDB" "https://raw.githubusercontent.com/borestad/blocklist-abuseipdb/main/abuseipdb-s100-30d.ipv4" "v4_abuseipdb.txt" "grep -v '^#' | awk '{print \$1}'" && FETCH_SUCCESS_COUNT=$((FETCH_SUCCESS_COUNT + 1)) || true
    FETCH_TOTAL=$((FETCH_TOTAL + 1)); fetch_list "IPsum" "https://raw.githubusercontent.com/stamparm/ipsum/master/levels/3.txt" "v4_ipsum.txt" "grep -v '^#'" && FETCH_SUCCESS_COUNT=$((FETCH_SUCCESS_COUNT + 1)) || true
    FETCH_TOTAL=$((FETCH_TOTAL + 1)); fetch_list "Spamhaus DROP" "https://www.spamhaus.org/drop/drop.txt" "v4_drop.txt" "grep -v '^;' | awk '{print \$1}' | cut -d';' -f1" && FETCH_SUCCESS_COUNT=$((FETCH_SUCCESS_COUNT + 1)) || true
    FETCH_TOTAL=$((FETCH_TOTAL + 1)); fetch_list "Emerging Threats" "https://rules.emergingthreats.net/blockrules/compromised-ips.txt" "v4_et.txt" "grep -v '^#'" && FETCH_SUCCESS_COUNT=$((FETCH_SUCCESS_COUNT + 1)) || true
    FETCH_TOTAL=$((FETCH_TOTAL + 1)); fetch_list "Feodo Tracker" "https://feodotracker.abuse.ch/downloads/ipblocklist.txt" "v4_feodo.txt" "grep -v '^#'" && FETCH_SUCCESS_COUNT=$((FETCH_SUCCESS_COUNT + 1)) || true
    FETCH_TOTAL=$((FETCH_TOTAL + 1)); fetch_list "URLhaus" "https://urlhaus.abuse.ch/downloads/text_online/" "v4_urlhaus.txt" "grep -oE '([0-9]{1,3}\\.){3}[0-9]{1,3}'" && FETCH_SUCCESS_COUNT=$((FETCH_SUCCESS_COUNT + 1)) || true
    FETCH_TOTAL=$((FETCH_TOTAL + 1)); fetch_list "CI Army" "https://cinsscore.com/list/ci-badguys.txt" "v4_ci.txt" "grep -v '^#'" && FETCH_SUCCESS_COUNT=$((FETCH_SUCCESS_COUNT + 1)) || true
    FETCH_TOTAL=$((FETCH_TOTAL + 1)); fetch_list "Binary Defense" "https://www.binarydefense.com/banlist.txt" "v4_binary.txt" "grep -v '^#'" && FETCH_SUCCESS_COUNT=$((FETCH_SUCCESS_COUNT + 1)) || true
    FETCH_TOTAL=$((FETCH_TOTAL + 1)); fetch_list "Bruteforce Blocker" "https://danger.rulez.sk/projects/bruteforceblocker/blist.php" "v4_bruteforce.txt" "grep -v '^#'" && FETCH_SUCCESS_COUNT=$((FETCH_SUCCESS_COUNT + 1)) || true
    FETCH_TOTAL=$((FETCH_TOTAL + 1)); fetch_list "Tor Exit Nodes" "https://check.torproject.org/torbulkexitlist" "v4_tor.txt" "grep -v '^#'" && FETCH_SUCCESS_COUNT=$((FETCH_SUCCESS_COUNT + 1)) || true
    FETCH_TOTAL=$((FETCH_TOTAL + 1)); fetch_list "Blocklist.de" "https://lists.blocklist.de/lists/all.txt" "v4_blocklist_de.txt" "grep -v '^#'" && FETCH_SUCCESS_COUNT=$((FETCH_SUCCESS_COUNT + 1)) || true
    FETCH_TOTAL=$((FETCH_TOTAL + 1)); fetch_list "Blocklist.de SSH" "https://lists.blocklist.de/lists/ssh.txt" "v4_blocklist_ssh.txt" "grep -v '^#'" && FETCH_SUCCESS_COUNT=$((FETCH_SUCCESS_COUNT + 1)) || true
    FETCH_TOTAL=$((FETCH_TOTAL + 1)); fetch_list "Blocklist.de Apache" "https://lists.blocklist.de/lists/apache.txt" "v4_blocklist_apache.txt" "grep -v '^#'" && FETCH_SUCCESS_COUNT=$((FETCH_SUCCESS_COUNT + 1)) || true
    FETCH_TOTAL=$((FETCH_TOTAL + 1)); fetch_list "Blocklist.de mail" "https://lists.blocklist.de/lists/mail.txt" "v4_blocklist_mail.txt" "grep -v '^#'" && FETCH_SUCCESS_COUNT=$((FETCH_SUCCESS_COUNT + 1)) || true
    FETCH_TOTAL=$((FETCH_TOTAL + 1)); fetch_list "GreenSnow" "https://blocklist.greensnow.co/greensnow.txt" "v4_greensnow.txt" "grep -v '^#'" && FETCH_SUCCESS_COUNT=$((FETCH_SUCCESS_COUNT + 1)) || true
    FETCH_TOTAL=$((FETCH_TOTAL + 1)); fetch_list "DShield" "https://feeds.dshield.org/block.txt" "v4_dshield.txt" "grep -v '^#' | awk '{print \$1 \"/\" \$3}'" && FETCH_SUCCESS_COUNT=$((FETCH_SUCCESS_COUNT + 1)) || true
    FETCH_TOTAL=$((FETCH_TOTAL + 1)); fetch_list "Botscout" "https://raw.githubusercontent.com/firehol/blocklist-ipsets/refs/heads/master/botscout_7d.ipset" "v4_botscout.txt" "grep -v '^#'" && FETCH_SUCCESS_COUNT=$((FETCH_SUCCESS_COUNT + 1)) || true
    FETCH_TOTAL=$((FETCH_TOTAL + 1)); fetch_list "Firehol level1" "https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/firehol_level1.netset" "v4_firehol_l1.txt" "grep -v '^#'" && FETCH_SUCCESS_COUNT=$((FETCH_SUCCESS_COUNT + 1)) || true
    FETCH_TOTAL=$((FETCH_TOTAL + 1)); fetch_list "Firehol level2" "https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/firehol_level2.netset" "v4_firehol_l2.txt" "grep -v '^#'" && FETCH_SUCCESS_COUNT=$((FETCH_SUCCESS_COUNT + 1)) || true
    FETCH_TOTAL=$((FETCH_TOTAL + 1)); fetch_list "Firehol level3" "https://raw.githubusercontent.com/firehol/blocklist-ipsets/refs/heads/master/firehol_level3.netset" "v4_firehol_l3.txt" "grep -v '^#'" && FETCH_SUCCESS_COUNT=$((FETCH_SUCCESS_COUNT + 1)) || true
    FETCH_TOTAL=$((FETCH_TOTAL + 1)); fetch_list "myip.ms" "https://raw.githubusercontent.com/firehol/blocklist-ipsets/refs/heads/master/myip.ipset" "v4_myip.txt" "grep -v '^#'" && FETCH_SUCCESS_COUNT=$((FETCH_SUCCESS_COUNT + 1)) || true
    FETCH_TOTAL=$((FETCH_TOTAL + 1)); fetch_list "SOCKS proxies" "https://raw.githubusercontent.com/firehol/blocklist-ipsets/refs/heads/master/socks_proxy_7d.ipset" "v4_socks_proxy.txt" "grep -v '^#'" && FETCH_SUCCESS_COUNT=$((FETCH_SUCCESS_COUNT + 1)) || true
    FETCH_TOTAL=$((FETCH_TOTAL + 1)); fetch_list "Botvrij" "https://www.botvrij.eu/data/ioclist.ip-dst.raw" "v4_botvrij.txt" "grep -v '^#'" && FETCH_SUCCESS_COUNT=$((FETCH_SUCCESS_COUNT + 1)) || true
    FETCH_TOTAL=$((FETCH_TOTAL + 1)); fetch_list "StopForumSpam" "https://www.stopforumspam.com/downloads/toxic_ip_cidr.txt" "v4_stopforumspam.txt" "grep -v '^#'" && FETCH_SUCCESS_COUNT=$((FETCH_SUCCESS_COUNT + 1)) || true
    FETCH_TOTAL=$((FETCH_TOTAL + 1)); fetch_list "Shodan scanners" "https://gist.githubusercontent.com/jfqd/4ff7fa70950626a11832a4bc39451c1c/raw" "v4_shodan.txt" "grep -v '^#'" && FETCH_SUCCESS_COUNT=$((FETCH_SUCCESS_COUNT + 1)) || true

    # Fetching IPv6 Lists
    FETCH_TOTAL=$((FETCH_TOTAL + 1)); fetch_list "Spamhaus DROPv6" "https://www.spamhaus.org/drop/dropv6.txt" "v6_drop.txt" "grep -v '^;' | awk '{print \$1}' | cut -d';' -f1" && FETCH_SUCCESS_COUNT=$((FETCH_SUCCESS_COUNT + 1)) || true

    log "Successfully fetched $FETCH_SUCCESS_COUNT/$FETCH_TOTAL lists"

    if [ "$FETCH_SUCCESS_COUNT" -eq 0 ]; then
        error "All list downloads failed. Keeping existing rules."
        exit 1
    fi

    log "Validating and cleaning IPs..."

    # IPv4 Processing with strict validation
    cat v4_*.txt 2>/dev/null | validate_ipv4 > clean_v4.txt || touch clean_v4.txt

    # IPv6 Processing with strict validation
    cat v6_*.txt 2>/dev/null | validate_ipv6 > clean_v6.txt || touch clean_v6.txt

    V4_RAW=$(cat v4_*.txt 2>/dev/null | wc -l || echo 0)
    V6_RAW=$(cat v6_*.txt 2>/dev/null | wc -l || echo 0)
    V4_CLEAN=$(wc -l < clean_v4.txt)
    V6_CLEAN=$(wc -l < clean_v6.txt)

    log "IPv4: $V4_RAW raw entries → $V4_CLEAN valid entries"
    log "IPv6: $V6_RAW raw entries → $V6_CLEAN valid entries"

    # Whitelisting
    touch whitelist_patterns.txt
    {
        echo "1.1.1.1"    # Cloudflare DNS
        echo "8.8.8.8"    # Google DNS
        echo "::1"        # IPv6 Localhost
        echo "2001:4860:4860::8888" # Google IPv6 DNS
        echo "2606:4700:4700::1111" # Cloudflare IPv6 DNS
    } >> whitelist_patterns.txt

    for pattern in $CUSTOM_WHITELIST; do
        echo "$pattern" >> whitelist_patterns.txt
    done

    log "Applying whitelist filters..."
    apply_whitelist clean_v4.txt step1_v4.txt
    apply_whitelist clean_v6.txt step1_v6.txt

    log "Optimizing lists (merging overlapping CIDRs)..."

    # Optimize with error handling
    cat step1_v4.txt | optimize_list > final_v4.txt 2>> "$LOG_FILE" || cp step1_v4.txt final_v4.txt
    cat step1_v6.txt | optimize_list > final_v6.txt 2>> "$LOG_FILE" || cp step1_v6.txt final_v6.txt

    # Safety Check
    log "Performing safety check..."

    TOTAL_IPS=$(( $(wc -l < final_v4.txt) + $(wc -l < final_v6.txt) ))
    if [ "$TOTAL_IPS" -lt "$MIN_IPS" ]; then
        error "Safety check failed: Only $TOTAL_IPS IPs found (minimum: $MIN_IPS)"
        error "This indicates a problem with list downloads. Keeping existing rules."
        exit 1
    fi

    log "Generating NFTables configuration..."

    if [ ! -s final_v4.txt ] && [ ! -s final_v6.txt ]; then
        error "No valid IPs to import. Exiting."
        exit 1
    fi

    V4_ELEMENTS=$(paste -sd "," final_v4.txt || echo "")
    V6_ELEMENTS=$(paste -sd "," final_v6.txt || echo "")

    NFT_FILE="apply_blocklist.nft"

    cat <<EOF > "$NFT_FILE"
table inet $NFT_TABLE {
EOF

    if [ -s final_v4.txt ]; then
        cat <<EOF >> "$NFT_FILE"
    set v4_list {
        type ipv4_addr
        flags interval
        auto-merge
        elements = { $V4_ELEMENTS }
    }
EOF
    fi

    if [ -s final_v6.txt ]; then
        cat <<EOF >> "$NFT_FILE"
    set v6_list {
        type ipv6_addr
        flags interval
        auto-merge
        elements = { $V6_ELEMENTS }
    }
EOF
    fi

    cat <<EOF >> "$NFT_FILE"
    chain inbound {
        type filter hook input priority -100; policy accept;
EOF

    if [ -s final_v4.txt ]; then
        echo "        ip saddr @v4_list drop" >> "$NFT_FILE"
    fi

    if [ -s final_v6.txt ]; then
        echo "        ip6 saddr @v6_list drop" >> "$NFT_FILE"
    fi

    cat <<EOF >> "$NFT_FILE"
    }
}
EOF

    # Apply to NFTables
    log "Applying rules to NFTables..."

    # Validate syntax before destroying existing table
    if ! nft -c -f "$NFT_FILE" 2>/dev/null; then
        error "Generated NFTables config has syntax errors. Keeping existing rules."
        cat "$NFT_FILE" >> "$LOG_FILE"
        exit 1
    fi

    if nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
        nft delete table inet "$NFT_TABLE"
    fi

    if nft -f "$NFT_FILE"; then
        V4_COUNT=$(wc -l < final_v4.txt)
        V6_COUNT=$(wc -l < final_v6.txt)
        log "✓ Success! Blocked $V4_COUNT IPv4 and $V6_COUNT IPv6 networks"
    else
        error "Failed to apply NFTables rules. Check syntax in $TEMP_DIR/$NFT_FILE"
        exit 1
    fi
}

main "$@"
