#!/usr/bin/env bash
set -euo pipefail

# Colours
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Global variables
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_FILE="${SCRIPT_DIR}/pangolin_dd_testfile"
readonly SUMMARY_FILE="${SCRIPT_DIR}/benchmark_results.json"
readonly MIN_FREE_SPACE=2  # GiB required for tests

# Options
SKIP_CPU=false
SKIP_DISK=false
SKIP_NET=false
SUDO_FALLBACK=false
USE_IPV6=false
OUTPUT_JSON=true

# Initialize summary data
declare -A SUMMARY_DATA=(
    ["hostname"]="$(hostname)"
    ["uptime"]="$(uptime -p)"
    ["timestamp"]="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    ["cpu_events_single"]=0
    ["cpu_events_multi"]=0
    ["disk_write_buffered_mb_s"]=0
    ["disk_write_direct_mb_s"]=0
    ["disk_read_mb_s"]=0
    ["network_method"]=""
    ["download_speed_mbps"]=0
    ["upload_speed_mbps"]=0
    ["ping_latency_ms"]=0
)

# Helper functions
error_exit() {
  printf "${RED}Error: %s${NC}\n" "$1" >&2
  cleanup
  exit 1
}

log_info() {
  printf "${GREEN}=== %s ===${NC}\n" "$1"
}

log_section() {
  printf "\n${YELLOW}%s${NC}\n" "$1"
}

log_summary() {
  printf "${BLUE}%s: %s${NC}\n" "$1" "$2"
}

show_usage() {
  cat << EOF
Usage: $0 [OPTIONS]

Options:
  --skip-cpu            Skip CPU benchmarks
  --skip-disk           Skip disk benchmarks  
  --skip-net            Skip network tests
  --sudo-fallback       Use sudo if not root
  --ipv6                Prefer IPv6 for speedtest
  --no-json             Disable JSON output
  --help                Show this help

Example: $0 --sudo-fallback --ipv6
EOF
}

# Parse command line options
while [[ $# -gt 0 ]]; do
  case $1 in
    --skip-cpu) SKIP_CPU=true; shift ;;
    --skip-disk) SKIP_DISK=true; shift ;;
    --skip-net) SKIP_NET=true; shift ;;
    --sudo-fallback) SUDO_FALLBACK=true; shift ;;
    --ipv6) USE_IPV6=true; shift ;;
    --no-json) OUTPUT_JSON=false; shift ;;
    --help) show_usage; exit 0 ;;
    *) error_exit "Unknown option: $1" ;;
  esac
done

# Cleanup function that preserves exit code
cleanup() {
  local exit_code=$?
  if [ -f "${TEST_FILE}" ]; then
    rm -f "${TEST_FILE}" || true
  fi
  # Save summary if tests ran
  if [ "${SUMMARY_DATA[hostname]}" != "" ] && [ "$OUTPUT_JSON" = true ]; then
    printf "%s\n" "$(jq -n --argjson data "${SUMMARY_DATA[*]}")" > "${SUMMARY_FILE}" 2>/dev/null || true
  fi
  exit $exit_code
}

trap cleanup EXIT

# Root check with sudo fallback
if [ "$(id -u)" -ne 0 ]; then
  if [ "$SUDO_FALLBACK" = true ]; then
    if command -v sudo >/dev/null 2>&1; then
      log_info "Relaunching with sudo..."
      exec sudo "$0" "$@"
    else
      error_exit "Not running as root and sudo is not available"
    fi
  else
    error_exit "Not running as root. Use --sudo-fallback or run with sudo."
  fi
fi

# Check available disk space
check_disk_space() {
  local available_gb
  available_gb=$(df -BG "${SCRIPT_DIR}" | tail -1 | awk '{print $4}' | sed 's/G//')
  if [ -z "$available_gb" ] || [ "$available_gb" -lt "$MIN_FREE_SPACE" ]; then
    error_exit "Insufficient disk space (need ${MIN_FREE_SPACE}GiB free in ${SCRIPT_DIR})"
  fi
  log_summary "Available space" "${available_gb}GiB"
}

# System Information Display
log_info "System Information"
printf "Hostname: %s\n" "${SUMMARY_DATA[hostname]}"
printf "Uptime: %s\n" "${SUMMARY_DATA[uptime]}"
printf "Timestamp: %s\n" "${SUMMARY_DATA[timestamp]}"
printf "CPU Info:\n"
lscpu | grep -E 'Model name|CPU\(s\)|Thread|Core|MHz|Architecture'
printf "\nMemory:\n"
free -h
printf "\nDisk:\n"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE

# Check disk space if disk tests will run
if [ "$SKIP_DISK" = false ]; then
  check_disk_space
fi

# Install dependencies based on package manager
log_section "Installing dependencies (sysbench + speedtest + fio + jq)"

install_debian_based() {
  apt-get update -yqq || error_exit "Failed to update apt cache"
  apt-get install -yqq sysbench curl ca-certificates fio jq || error_exit "Failed to install base packages"

  if ! command -v speedtest &>/dev/null; then
    if curl -sfS "https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh" | bash; then
      if apt-get install -yqq speedtest; then
        SUMMARY_DATA["network_method"]="ookla"
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
  dnf install -y sysbench curl ca-certificates fio jq || true

  if ! command -v sysbench &>/dev/null; then
    dnf install -y epel-release && dnf install -y sysbench || error_exit "Failed to install sysbench"
  fi

  if ! command -v speedtest &>/dev/null; then
    if curl -sfS "https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh" | bash; then
      if dnf install -y speedtest; then
        SUMMARY_DATA["network_method"]="ookla"
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
  yum install -y sysbench curl ca-certificates fio jq || error_exit "Failed to install base packages"

  if ! command -v speedtest &>/dev/null; then
    if curl -sfS "https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh" | bash; then
      if yum install -y speedtest; then
        SUMMARY_DATA["network_method"]="ookla"
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
  local pip_installed=false
  if ! command -v pip3 &>/dev/null; then
    if apt-get install -yqq python3-pip 2>/dev/null; then
      pip_installed=true
    elif dnf install -y python3-pip 2>/dev/null; then
      pip_installed=true
    elif yum install -y python3-pip 2>/dev/null; then
      pip_installed=true
    fi
  fi

  if [ "$pip_installed" = true ] || command -v pip3 &>/dev/null; then
    pip3 install speedtest-cli --break-system-packages >/dev/null 2>&1 || {
      printf "${YELLOW}Warning: Failed to install speedtest-cli via pip${NC}\n"
      SUMMARY_DATA["network_method"]="none"
      return 1
    }
    if command -v speedtest-cli &>/dev/null; then
      SUMMARY_DATA["network_method"]="python-cli"
      printf "${GREEN}✓${NC} speedtest-cli (Python) installed\n"
    fi
  else
    printf "${YELLOW}Warning: Could not install speedtest tool${NC}\n"
    SUMMARY_DATA["network_method"]="none"
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
  error_exit "Unsupported package manager. Please install: sysbench fio jq speedtest"
fi

# Verify required tools
if ! command -v sysbench &>/dev/null || ! command -v fio &>/dev/null || ! command -v jq &>/dev/null; then
  error_exit "Required tools (sysbench, fio, jq) not installed"
fi

if [ "${SUMMARY_DATA[network_method]}" = "none" ] && [ "$SKIP_NET" = false ]; then
  printf "${YELLOW}Warning: No speedtest tool available, network test will be skipped${NC}\n"
  SKIP_NET=true
fi

# Display tool versions
log_section "Tool Versions"
printf "sysbench: "
sysbench --version 2>/dev/null || printf "not available"
printf "\n"

if command -v speedtest &>/dev/null; then
  printf "speedtest: "
  speedtest --version 2>/dev/null || true
  printf "\n"
elif command -v speedtest-cli &>/dev/null; then
  printf "speedtest-cli: "
  speedtest-cli --version 2>/dev/null || true
  printf "\n"
fi

printf "fio: %s\n" "$(fio --version 2>/dev/null | head -1 || echo 'not available')"
printf "jq: %s\n" "$(jq --version 2>/dev/null || echo 'not available')"

# CPU Benchmarks with dynamic parameters
if [ "$SKIP_CPU" = false ]; then
  # Dynamic prime limit based on core count for better scaling
  local cpu_count
  cpu_count=$(nproc)
  local max_prime=$((cpu_count * 1000 + 20000))  # Scale with cores

  log_section "CPU Benchmark: Single Thread (time=10s, max-prime=${max_prime})"
  local single_output
  single_output=$(sysbench cpu --time=10 --threads=1 --cpu-max-prime="${max_prime}" run 2>&1) || error_exit "Single-thread CPU benchmark failed"

  # Extract key metrics
  SUMMARY_DATA["cpu_events_single"]=$(echo "${single_output}" | grep -oP 'events per second: \K\d+(?:\.\d+)?' || echo "0")
  echo "${single_output}" | grep -E "total time|events per second|Latency" || true

  log_section "CPU Benchmark: Multi Thread (${cpu_count} threads, time=10s, max-prime=${max_prime})"
  local multi_output
  multi_output=$(sysbench cpu --time=10 --threads="${cpu_count}" --cpu-max-prime="${max_prime}" run 2>&1) || error_exit "Multi-thread CPU benchmark failed"

  SUMMARY_DATA["cpu_events_multi"]=$(echo "${multi_output}" | grep -oP 'events per second: \K\d+(?:\.\d+)?' || echo "0")
  echo "${multi_output}" | grep -E "total time|events per second|Latency" || true
  log_summary "CPU Single: " "${SUMMARY_DATA[cpu_events_single]} events/s"
  log_summary "CPU Multi: " "${SUMMARY_DATA[cpu_events_multi]} events/s"
fi

# Enhanced Disk Benchmarks with fio for IOPS + read tests
if [ "$SKIP_DISK" = false ]; then
  log_section "Disk Benchmarks (Sequential + Random I/O)"

  # Sequential write buffered (dd for compatibility)
  log_section "Sequential Write (Buffered, 1GiB)"
  if dd if=/dev/zero of="${TEST_FILE}" bs=1M count=1024 conv=fdatasync status=progress 2>&1 | tee /dev/tty | tail -1 | grep -oP '(\d+(?:\.\d+)? [GM]B/s)' >/dev/null; then
    local buffered_speed
    buffered_speed=$(dd if=/dev/zero of="${TEST_FILE}" bs=1M count=1024 conv=fdatasync status=none 2>&1 | awk '/copied/ {print $(NF-1)}' | sed 's/ //g')
    SUMMARY_DATA["disk_write_buffered_mb_s"]=$(echo "${buffered_speed}" | sed 's/GiB/s/MB\/s/;s/MiB/s/MB\/s/' || echo "0")
    printf "${GREEN}✓${NC} Buffered write: ${buffered_speed}\n"
  else
    printf "${RED}✗${NC} Buffered write failed\n"
  fi

  # Sequential write direct I/O (fixed with both flags)
  log_section "Sequential Write (Direct I/O, 1GiB)"
  if dd if=/dev/zero of="${TEST_FILE}" bs=1M count=1024 iflag=direct oflag=direct status=progress 2>&1 | tee /dev/tty; then
    local direct_speed
    direct_speed=$(dd if=/dev/zero of="${TEST_FILE}" bs=1M count=1024 iflag=direct oflag=direct status=none 2>&1 | awk '/copied/ {print $(NF-1)}' | sed 's/ //g')
    SUMMARY_DATA["disk_write_direct_mb_s"]=$(echo "${direct_speed}" | sed 's/GiB/s/MB\/s/;s/MiB/s/MB\/s/' || echo "0")
    printf "${GREEN}✓${NC} Direct I/O write: ${direct_speed}\n"
  else
    printf "${YELLOW}Warning: Direct I/O write failed (may not be supported)${NC}\n"
  fi

  # Sequential read test
  log_section "Sequential Read (1GiB)"
  if dd if="${TEST_FILE}" of=/dev/null bs=1M count=1024 iflag=direct status=progress 2>&1 | tee /dev/tty; then
    local read_speed
    read_speed=$(dd if="${TEST_FILE}" of=/dev/null bs=1M count=1024 iflag=direct status=none 2>&1 | awk '/copied/ {print $(NF-1)}' | sed 's/ //g')
    SUMMARY_DATA["disk_read_mb_s"]=$(echo "${read_speed}" | sed 's/GiB/s/MB\/s/;s/MiB/s/MB\/s/' || echo "0")
    printf "${GREEN}✓${NC} Read: ${read_speed}\n"
  else
    printf "${YELLOW}Warning: Read test failed${NC}\n"
  fi

  # FIO random I/O tests for IOPS
  log_section "Random I/O (FIO - 4K blocks, 1GiB)"
  local fio_config
  fio_config="${SCRIPT_DIR}/fio_test.cfg"
  cat > "${fio_config}" << EOF
[global]
ioengine=libaio
direct=1
filename=${TEST_FILE}
size=1G
bs=4k
iodepth=32
numjobs=4
runtime=30
group_reporting=1
output-format=normal

[randread]
rw=randread
time_based=1

[randwrite]
rw=randwrite
time_based=1
EOF

  local fio_output
  fio_output=$(fio "${fio_config}" 2>&1) || printf "${YELLOW}Warning: FIO test completed with warnings${NC}\n"
  echo "${fio_output}" | grep -E "read:|write:|IOPS|BW="

  rm -f "${fio_config}"
  log_summary "Disk Space Used" "$(du -h "${TEST_FILE}" 2>/dev/null | cut -f1 || echo 'unknown')"
fi

# Network Speed Test with IPv6 support and JSON parsing
if [ "$SKIP_NET" = false ] && [ "${SUMMARY_DATA[network_method]}" != "none" ]; then
  log_section "Network Speed Test (${SUMMARY_DATA[network_method]}, IPv6: ${USE_IPV6})"

  run_speedtest() {
    if command -v speedtest &>/dev/null; then
      # Ookla with IPv6 preference if requested
      if [ "$USE_IPV6" = true ]; then
        speedtest --accept-license --accept-gdpr -f json --prefer-ipv6 2>/dev/null || speedtest --accept-license --accept-gdpr -f json
      else
        speedtest --accept-license --accept-gdpr -f json 2>/dev/null || speedtest --accept-license --accept-gdpr -f json
      fi
    elif command -v speedtest-cli &>/dev/null; then
      # Python CLI - simple mode, no native IPv6 preference
      speedtest-cli --simple --json 2>/dev/null || speedtest-cli --simple
    fi
  }

  local speedtest_output
  speedtest_output=$(run_speedtest) || {
    printf "${YELLOW}Warning: Network speed test failed${NC}\n"
    return 1
  }

  # Parse JSON output if available
  if echo "${speedtest_output}" | jq . >/dev/null 2>&1; then
    SUMMARY_DATA["download_speed_mbps"]=$(echo "${speedtest_output}" | jq -r '.download // .downloadSpeed' 2>/dev/null | awk '{print int($1/1000000)}' || echo "0")
    SUMMARY_DATA["upload_speed_mbps"]=$(echo "${speedtest_output}" | jq -r '.upload // .uploadSpeed' 2>/dev/null | awk '{print int($1/1000000)}' || echo "0")
    SUMMARY_DATA["ping_latency_ms"]=$(echo "${speedtest_output}" | jq -r '.ping // .pingLatency' 2>/dev/null || echo "0")
    echo "${speedtest_output}" | jq . || cat "${speedtest_output}"

    log_summary "Download" "${SUMMARY_DATA[download_speed_mbps]} Mbps"
    log_summary "Upload" "${SUMMARY_DATA[upload_speed_mbps]} Mbps"  
    log_summary "Latency" "${SUMMARY_DATA[ping_latency_ms]} ms"
  else
    # Fallback to simple parsing for non-JSON output
    echo "${speedtest_output}"
    local dl_match ul_match lat_match
    dl_match=$(echo "${speedtest_output}" | grep -oP 'Download: \K\d+(?:\.\d+)?' | head -1)
    ul_match=$(echo "${speedtest_output}" | grep -oP 'Upload: \K\d+(?:\.\d+)?' | head -1)
    lat_match=$(echo "${speedtest_output}" | grep -oP 'Ping: \K\d+(?:\.\d+)?' | head -1)

    SUMMARY_DATA["download_speed_mbps"]="${dl_match:-0}"
    SUMMARY_DATA["upload_speed_mbps"]="${ul_match:-0}"  
    SUMMARY_DATA["ping_latency_ms"]="${lat_match:-0}"
  fi

  printf "${GREEN}✓${NC} Network test complete\n"
else
  printf "${YELLOW}Network test skipped${NC}\n"
fi

# Final summary and JSON output
log_info "Benchmark Summary"
if [ "$SKIP_CPU" = false ]; then
  log_summary "CPU (Single)" "${SUMMARY_DATA[cpu_events_single]} events/s"
  log_summary "CPU (Multi)" "${SUMMARY_DATA[cpu_events_multi]} events/s"
fi
if [ "$SKIP_DISK" = false ]; then
  log_summary "Disk Write (Buffered)" "${SUMMARY_DATA[disk_write_buffered_mb_s]}"
  log_summary "Disk Write (Direct)" "${SUMMARY_DATA[disk_write_direct_mb_s]}"
  log_summary "Disk Read" "${SUMMARY_DATA[disk_read_mb_s]}"
fi
if [ "$SKIP_NET" = false ] && [ "${SUMMARY_DATA[network_method]}" != "none" ]; then
  log_summary "Download" "${SUMMARY_DATA[download_speed_mbps]} Mbps"
  log_summary "Upload" "${SUMMARY_DATA[upload_speed_mbps]} Mbps"
  log_summary "Ping" "${SUMMARY_DATA[ping_latency_ms]} ms"
fi

if [ "$OUTPUT_JSON" = true ] && [ -f "${SUMMARY_FILE}" ]; then
  printf "\n${GREEN}✓${NC} Detailed results saved to: ${SUMMARY_FILE}\n"
  cat "${SUMMARY_FILE}"
fi

log_info "Benchmarking Complete"
printf "Test artifacts cleaned up. Results preserved in ${SUMMARY_FILE} if JSON enabled.\n"
