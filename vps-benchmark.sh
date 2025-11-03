#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C LANG=C # Force C locale for all output

# Color output for better readability
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

# Global variables
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_FILE="${SCRIPT_DIR}/a_testfile"
INSTALL_SPEEDTEST_CLI="ookla"

# --- Metric variables ---
cpu_events_single=0
cpu_events_multi=0
disk_write_buffered_mb_s=0
disk_write_direct_mb_s=0
disk_read_mb_s=0
network_download_mbps=0
network_upload_mbps=0
network_ping_ms=0

# Error handling
error_exit() {
  printf "${RED}Error: %s${NC}\n" "$1" >&2
  exit 1
}

log_info() { # Big sections
  printf "\n${YELLOW}=== %s ===${NC}\n" "$1"
}

log_section() { # Sub-sections
  printf "\n${GREEN}%s${NC}\n" "$1"
}

log_summary_header() {
  printf "\n${GREEN}===================================${NC}\n"
  printf "${GREEN}    %s${NC}\n" "$1"
  printf "${GREEN}===================================${NC}\n"
}

cleanup() {
  local exit_code=$?
  if [ -f "${TEST_FILE}" ]; then
    rm -f "${TEST_FILE}" || true
  fi
  exit ${exit_code}
}

trap cleanup EXIT

# Check if running as root for package installations
if [ "$(id -u)" -ne 0 ]; then
  error_exit "This script must run as root for package installations"
fi

# System Information Display
log_info "System Info"
printf "Hostname: %s\n" "$(hostname)"
printf "Uptime: %s\n" "$(uptime -p)"
printf "CPU Info:\n"
lscpu | grep -E '^Model name:|^CPU\(s\):|^Thread\(s\) per core:|^Core\(s\) per socket:' | sed 's/^[ \t]*//'
printf "\nMemory:\n"
free -h
printf "\nDisk:\n"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT

# Install dependencies based on package manager
log_info "Dependencies"
log_section "Installing dependencies (sysbench + speedtest + bc)"

install_debian_based() {
  apt-get update -y || error_exit "Failed to update apt cache"
  apt-get install -y sysbench curl ca-certificates bc || error_exit "Failed to install base packages"

  if ! command -v speedtest &>/dev/null; then
    if curl -sfS "https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh" | bash; then
      if apt-get install -y speedtest; then
        printf "${GREEN}✓${NC} Ookla Speedtest installed\n"
      else
        install_speedtest_python
      fi
    else
      install_speedtest_python
    fi
  fi
}

install_fedora_based() {
  dnf install -y sysbench curl ca-certificates bc || true

  if ! command -v sysbench &>/dev/null; then
    dnf install -y epel-release && dnf install -y sysbench || error_exit "Failed to install sysbench"
  fi
  if ! command -v bc &>/dev/null; then
    dnf install -y bc || error_exit "Failed to install bc"
  fi

  if ! command -v speedtest &>/dev/null; then
    if curl -sfS "https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh" | bash; then
      if dnf install -y speedtest; then
        printf "${GREEN}✓${NC} Ookla Speedtest installed\n"
      else
        install_speedtest_python
      fi
    else
      install_speedtest_python
    fi
  fi
}

install_redhat_based() {
  yum install -y epel-release || true
  yum install -y sysbench curl ca-certificates bc || error_exit "Failed to install base packages"

  if ! command -v speedtest &>/dev/null; then
    if curl -sfS "https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh" | bash; then
      if yum install -y speedtest; then
        printf "${GREEN}✓${NC} Ookla Speedtest installed\n"
      else
        install_speedtest_python
      fi
    else
      install_speedtest_python
    fi
  fi
}

install_speedtest_python() {
  if command -v pip3 &>/dev/null || apt-get install -y python3-pip || dnf install -y python3-pip || yum install -y python3-pip; then
    pip3 install --break-system-packages speedtest-cli 2>/dev/null || {
      printf "${YELLOW}Warning: Failed to install speedtest-cli via pip${NC}\n"
      INSTALL_SPEEDTEST_CLI="none"
    }
    if command -v speedtest-cli &>/dev/null; then
      INSTALL_SPEEDTEST_CLI="python"
      printf "${GREEN}✓${NC} speedtest-cli (Python) installed\n"
    fi
  else
    printf "${YELLOW}Warning: Could not install pip or speedtest-cli${NC}\n"
    INSTALL_SPEEDTEST_CLI="none"
  fi
}

# Detect and use appropriate package manager
if command -v apt-get &>/dev/null; then
  install_debian_based
elif command -v dnf &>/dev/null; then
  install_fedora_based
elif command -v yum &>/dev/null; then
  install_redhat_based
else
  error_exit "Unsupported package manager. Please install sysbench, bc, and speedtest manually."
fi

# Display tool versions
log_section "Tool Versions"
sysbench --version || printf "${YELLOW}Warning: sysbench not available${NC}\n"
bc --version | head -n 1 || printf "${YELLOW}Warning: bc not available${NC}\n"

if command -v speedtest &>/dev/null; then
  speedtest --version | head -n 1 || true
elif command -v speedtest-cli &>/dev/null; then
  speedtest-cli --version | head -n 1 || true
else
  printf "${YELLOW}Warning: No speedtest tool available${NC}\n"
fi

# --- Helper function to parse dd output ---
parse_dd() {
  local dd_output="$1"
  local speed
  speed=$(echo "$dd_output" | grep -Eo '[0-9]+(\.[0-9]+)? [GM]B/s' | tail -n 1)
  if echo "$speed" | grep -q "GB/s"; then
    echo "$speed" | awk '{print $1 * 1024}' | cut -d'.' -f1
  else
    echo "$speed" | awk '{print $1}' | cut -d'.' -f1
  fi
}

log_info "Starting Benchmarks"

# CPU Benchmarks
log_section "CPU Benchmark: Single Thread (time=10s, max-prime=20000)"
cpu_out_single=$(sysbench cpu --time=10 --threads=1 --cpu-max-prime=20000 run)
echo "$cpu_out_single" | grep 'events per second:' | sed 's/^[ \t]*//'
cpu_events_single=$(echo "$cpu_out_single" | awk -F': ' '/events per second:/ {print $2; exit}')

cpu_count=$(nproc)
log_section "CPU Benchmark: Multi Thread (${cpu_count} threads, time=10s, max-prime=20000)"
cpu_out_multi=$(sysbench cpu --time=10 --threads="${cpu_count}" --cpu-max-prime=20000 run)
echo "$cpu_out_multi" | grep 'events per second:' | sed 's/^[ \t]*//'
cpu_events_multi=$(echo "$cpu_out_multi" | awk -F': ' '/events per second:/ {print $2; exit}')


# Disk Benchmarks
log_section "Disk Write (1GiB, buffered+flush)"
dd_out_buffered=$(dd if=/dev/zero of="${TEST_FILE}" bs=1M count=1024 conv=fdatasync status=progress 2>&1 | tail -n 1)
echo "$dd_out_buffered"
disk_write_buffered_mb_s=$(parse_dd "$dd_out_buffered")

log_section "Disk Write (1GiB, direct I/O)"
dd_out_direct=$(dd if=/dev/zero of="${TEST_FILE}" bs=1M count=1024 oflag=direct status=progress 2>&1 | tail -n 1)
echo "$dd_out_direct"
disk_write_direct_mb_s=$(parse_dd "$dd_out_direct")

log_section "Disk Read (1GiB, direct I/O)"
dd_out_read=$(dd if="${TEST_FILE}" of=/dev/null bs=1M count=1024 iflag=direct status=progress 2>&1 | tail -n 1)
echo "$dd_out_read"
disk_read_mb_s=$(parse_dd "$dd_out_read")


# Network Speed Test
log_section "Network Speed Test (${INSTALL_SPEEDTEST_CLI})"

run_speedtest() {
  if command -v speedtest &>/dev/null; then
    local json_out
    json_out=$(speedtest --accept-license --accept-gdpr -f json 2>/dev/null) || {
      speedtest --accept-license --accept-gdpr
      return 1
    }
    network_download_mbps=$(echo "$json_out" | grep -o '"download":{[^}]*}' | grep -o '"bandwidth":[0-9]*' | awk -F':' '{print $2 / 125000}' | cut -d'.' -f1)
    network_upload_mbps=$(echo "$json_out" | grep -o '"upload":{[^}]*}' | grep -o '"bandwidth":[0-9]*' | awk -F':' '{print $2 / 125000}' | cut -d'.' -f1)
    network_ping_ms=$(echo "$json_out" | grep -o '"ping":{[^}]*}' | grep -o '"latency":[0-9.]*' | awk -F':' '{print $2}')
    
  elif command -v speedtest-cli &>/dev/null; then
    local simple_out
    simple_out=$(speedtest-cli --simple)
    echo "$simple_out"
    network_download_mbps=$(echo "$simple_out" | awk '/Download:/ {print $2}' | cut -d'.' -f1)
    network_upload_mbps=$(echo "$simple_out" | awk '/Upload:/ {print $2}' | cut -d'.' -f1)
    network_ping_ms=$(echo "$simple_out" | awk '/Ping:/ {print $2}')

  else
    printf "${RED}No speedtest tool available${NC}\n"
    return 1
  fi
}

if run_speedtest; then
  printf "${GREEN}✓${NC} Network speed test complete\n"
else
  printf "${YELLOW}Warning: Network speed test failed or unavailable${NC}\n"
fi

# --- Final Summary ---
log_summary_header "FINAL RESULTS SUMMARY"

printf "\n${CYAN}CPU Performance (sysbench):${NC}\n"
printf "  %-20s: ${GREEN}%s${NC} events/sec\n" "Single-Thread" "$cpu_events_single"
printf "  %-20s: ${GREEN}%s${NC} events/sec\n" "Multi-Thread" "$cpu_events_multi"

printf "\n${CYAN}Disk Performance (dd 1GiB):${NC}\n"
printf "  %-20s: ${GREEN}%s${NC} MB/s\n" "Write (Buffered)" "$disk_write_buffered_mb_s"
printf "  %-20s: ${GREEN}%s${NC} MB/s\n" "Write (Direct)" "$disk_write_direct_mb_s"
printf "  %-20s: ${GREEN}%s${NC} MB/s\n" "Read (Direct)" "$disk_read_mb_s"

printf "\n${CYAN}Network Performance (speedtest):${NC}\n"
printf "  %-20s: ${GREEN}%s${NC} Mbps\n" "Download" "$network_download_mbps"
printf "  %-20s: ${GREEN}%s${NC} Mbps\n" "Upload" "$network_upload_mbps"
printf "  %-20s: ${GREEN}%s${NC} ms\n" "Latency" "$network_ping_ms"

printf "\n${GREEN}System benchmarking completed successfully.${NC}\n"
