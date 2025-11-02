#!/usr/bin/env bash
set -euo pipefail

## Usage
#
# Run full suite with sudo fallback and IPv6 preference:
# sudo ./vps-benchmark.sh --sudo-fallback --ipv6
#
# Skip network tests and disable JSON:
# sudo ./vps-benchmark.sh --skip-net --no-json
#
# View help:
# ./vps-benchmark.sh --help

# Colours
readonly RED='[0;31m'
readonly GREEN='[0;32m'
readonly YELLOW='[1;33m'
readonly BLUE='[0;34m'
readonly NC='[0m' # No Color

# Global variables
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_FILE="${SCRIPT_DIR}/pangolin_dd_testfile"
readonly SUMMARY_FILE="${SCRIPT_DIR}/benchmark_results.json"
readonly MIN_FREE_SPACE=2  # GiB required for tests

# Options
SKIP_CPU=false
SKIP_DISK=false
SKIP_NET=false
SUDO_FALLBACK=false
USE_IPV6=false
OUTPUT_JSON=true

# Initialize summary data as regular variables
hostname="$(hostname)"
uptime="$(uptime -p)"
timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cpu_events_single=0
cpu_events_multi=0
disk_write_buffered_mb_s=0
disk_write_direct_mb_s=0
disk_read_mb_s=0
network_method=""
download_speed_mbps=0
upload_speed_mbps=0
ping_latency_ms=0

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
  if [ -f "$TEST_FILE" ]; then
    printf "${YELLOW}Cleaning up test file: %s${NC}\n" "$TEST_FILE"
    rm -f "$TEST_FILE" || printf "${YELLOW}Warning: Could not remove %s${NC}\n" "$TEST_FILE"
  fi
  # Save summary if tests ran and JSON enabled
  if [ "$OUTPUT_JSON" = true ] && [ -n "$hostname" ]; then
    local summary_json
    summary_json=$(cat << EOF
{
  "hostname": "${hostname}",
  "uptime": "${uptime}",
  "timestamp": "${timestamp}",
  "cpu_events_single": ${cpu_events_single},
  "cpu_events_multi": ${cpu_events_multi},
  "disk_write_buffered_mb_s": ${disk_write_buffered_mb_s},
  "disk_write_direct_mb_s": ${disk_write_direct_mb_s},
  "disk_read_mb_s": ${disk_read_mb_s},
  "network_method": "${network_method}",
  "download_speed_mbps": ${download_speed_mbps},
  "upload_speed_mbps": ${upload_speed_mbps},
  "ping_latency_ms": ${ping_latency_ms}
}
EOF
    )
    printf "%s\n" "$summary_json" > "${SUMMARY_FILE}" 2>/dev/null || printf "${YELLOW}Warning: Could not save JSON to %s${NC}\n" "${SUMMARY_FILE}"
    printf "${GREEN}✓${NC} Results saved to: ${SUMMARY_FILE}\n"
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
  if [ -z "$available_gb" ] || (( $(echo "$available_gb < $MIN_FREE_SPACE" | bc -l) )); then
    error_exit "Insufficient disk space (need ${MIN_FREE_SPACE}GiB free in ${SCRIPT_DIR})"
  fi
  log_summary "Available space" "${available_gb}GiB"
  printf "${GREEN}✓${NC} Disk space check passed for: ${SCRIPT_DIR}\n"
}

# System Information Display
log_info "System Information"
printf "Hostname: %s\n" "$hostname"
printf "Uptime: %s\n" "$uptime"
printf "Timestamp: %s\n" "$timestamp"
printf "Script directory: %s\n" "$SCRIPT_DIR"
printf "Test file location: %s\n" "$TEST_FILE"
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
log_section "Installing dependencies (sysbench + speedtest + fio + jq + bc)"

install_debian_based() {
  apt-get update -yqq || error_exit "Failed to update apt cache"
  apt-get install -yqq sysbench curl ca-certificates fio jq bc || error_exit "Failed to install base packages"

  if ! command -v speedtest >/dev/null 2>&1; then
    printf "${YELLOW}Installing Ookla Speedtest CLI...${NC}\n"
    if curl -sfS "https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh" | bash; then
      if apt-get install -yqq speedtest; then
        network_method="ookla"
        printf "${GREEN}✓${NC} Ookla Speedtest installed\n"
      else
        install_speedtest_python
      fi
    else
      install_speedtest_python
    fi
  else
    network_method="ookla"
    printf "${GREEN}✓${NC} Speedtest already available\n"
  fi
}

install_fedora_based() {
  dnf install -y sysbench curl ca-certificates fio jq bc || true

  if ! command -v sysbench >/dev/null 2>&1; then
    dnf install -y epel-release && dnf install -y sysbench || error_exit "Failed to install sysbench"
  fi

  if ! command -v speedtest >/dev/null 2>&1; then
    printf "${YELLOW}Installing Ookla Speedtest CLI...${NC}\n"
    if curl -sfS "https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh" | bash; then
      if dnf install -y speedtest; then
        network_method="ookla"
        printf "${GREEN}✓${NC} Ookla Speedtest installed\n"
      else
        install_speedtest_python
      fi
    else
      install_speedtest_python
    fi
  else
    network_method="ookla"
    printf "${GREEN}✓${NC} Speedtest already available\n"
  fi
}

install_redhat_based() {
  yum install -y epel-release || true
  yum install -y sysbench curl ca-certificates fio jq bc || error_exit "Failed to install base packages"

  if ! command -v speedtest >/dev/null 2>&1; then
    printf "${YELLOW}Installing Ookla Speedtest CLI...${NC}\n"
    if curl -sfS "https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh" | bash; then
      if yum install -y speedtest; then
        network_method="ookla"
        printf "${GREEN}✓${NC} Ookla Speedtest installed\n"
      else
        install_speedtest_python
      fi
    else
      install_speedtest_python
    fi
  else
    network_method="ookla"
    printf "${GREEN}✓${NC} Speedtest already available\n"
  fi
}

install_speedtest_python() {
  local pip_installed=false
  if ! command -v pip3 >/dev/null 2>&1; then
    if apt-get install -yqq python3-pip 2>/dev/null; then
      pip_installed=true
    elif dnf install -y python3-pip 2>/dev/null; then
      pip_installed=true
    elif yum install -y python3-pip 2>/dev/null; then
      pip_installed=true
    fi
  fi

  if [ "$pip_installed" = true ] || command -v pip3 >/dev/null 2>&1; then
    printf "${YELLOW}Installing speedtest-cli via pip...${NC}\n"
    pip3 install speedtest-cli --break-system-packages >/dev/null 2>&1 || {
      printf "${YELLOW}Warning: Failed to install speedtest-cli via pip${NC}\n"
      network_method="none"
      return 1
    }
    if command -v speedtest-cli >/dev/null 2>&1; then
      network_method="python-cli"
      printf "${GREEN}✓${NC} speedtest-cli (Python) installed\n"
    fi
  else
    printf "${YELLOW}Warning: Could not install speedtest tool${NC}\n"
    network_method="none"
  fi
}

# Detect and use appropriate package manager
if command -v apt-get >/dev/null 2>&1; then
  install_debian_based
elif command -v dnf >/dev/null 2>&1; then
  install_fedora_based
elif command -v yum >/dev/null 2>&1; then
  install_redhat_based
else
  error_exit "Unsupported package manager. Please install: sysbench fio jq bc speedtest"
fi

# Verify required tools
if ! command -v sysbench >/dev/null 2>&1 || ! command -v fio >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || ! command -v bc >/dev/null 2>&1; then
  error_exit "Required tools (sysbench, fio, jq, bc) not installed"
fi

if [ "$network_method" = "none" ] && [ "$SKIP_NET" = false ]; then
  printf "${YELLOW}Warning: No speedtest tool available, network test will be skipped${NC}\n"
  SKIP_NET=true
fi

# Display tool versions
log_section "Tool Versions"
printf "sysbench: "
sysbench --version 2>/dev/null || printf "not available"
printf "\n"

if command -v speedtest >/dev/null 2>&1; then
  printf "speedtest: "
  speedtest --version 2>/dev/null || true
  printf "\n"
elif command -v speedtest-cli >/dev/null 2>&1; then
  printf "speedtest-cli: "
  speedtest-cli --version 2>/dev/null || true
  printf "\n"
fi

printf "fio: %s\n" "$(fio --version 2>/dev/null | head -1 || echo 'not available')"
printf "jq: %s\n" "$(jq --version 2>/dev/null || echo 'not available')"
printf "bc: %s\n" "$(bc --version 2>/dev/null | head -1 || echo 'not available')"

# CPU Benchmarks with dynamic parameters
cpu_benchmark() {
  local cpu_count
  cpu_count=$(nproc)
  local max_prime=$((cpu_count * 1000 + 20000))  # Scale with cores

  log_section "CPU Benchmark: Single Thread (time=10s, max-prime=${max_prime})"
  local single_output
  single_output=$(sysbench cpu --time=10 --threads=1 --cpu-max-prime="${max_prime}" run 2>&1)
  if [ $? -eq 0 ]; then
    cpu_events_single=$(echo "${single_output}" | grep -oP 'events per second: \K\d+(?:\.?\d+)?' || echo "0")
    echo "${single_output}" | grep -E "total time|events per second|Latency"
    printf "${GREEN}✓${NC} Single-thread CPU test completed\n"
  else
    printf "${RED}✗${NC} Single-thread CPU benchmark failed\n"
    cpu_events_single=0
  fi

  log_section "CPU Benchmark: Multi Thread (${cpu_count} threads, time=10s, max-prime=${max_prime})"
  local multi_output
  multi_output=$(sysbench cpu --time=10 --threads="${cpu_count}" --cpu-max-prime="${max_prime}" run 2>&1)
  if [ $? -eq 0 ]; then
    cpu_events_multi=$(echo "${multi_output}" | grep -oP 'events per second: \K\d+(?:\.?\d+)?' || echo "0")
    echo "${multi_output}" | grep -E "total time|events per second|Latency"
    log_summary "CPU Single: " "${cpu_events_single} events/s"
    log_summary "CPU Multi: " "${cpu_events_multi} events/s"
    printf "${GREEN}✓${NC} Multi-thread CPU test completed\n"
  else
    printf "${RED}✗${NC} Multi-thread CPU benchmark failed\n"
    cpu_events_multi=0
  fi
}

if [ "$SKIP_CPU" = false ]; then
  cpu_benchmark
fi

# Enhanced Disk Benchmarks with fio for IOPS + read tests
disk_benchmark() {
  printf "${GREEN}Creating test file at: %s${NC}\n" "$TEST_FILE"

  # Ensure test file directory exists
  local test_dir
  test_dir="$(dirname "$TEST_FILE")"
  if [ ! -d "$test_dir" ]; then
    mkdir -p "$test_dir" || error_exit "Could not create directory: $test_dir"
    printf "${GREEN}✓${NC} Created directory: %s\n" "$test_dir"
  fi

  # Sequential write buffered (dd for compatibility)
  log_section "Sequential Write (Buffered, 1GiB) -> ${TEST_FILE}"
  if dd if=/dev/zero of="$TEST_FILE" bs=1M count=1024 conv=fdatasync status=progress 2>&1; then
    local buffered_speed
    buffered_speed=$(dd if=/dev/zero of="$TEST_FILE" bs=1M count=1024 conv=fdatasync status=none 2>&1 | awk '/copied/ {print $(NF-1)}' | sed 's/ //g' || echo "0 MiB/s")
    # Convert to MB/s (1 GiB/s = 1024 MB/s, 1 MiB/s = 1 MB/s)
    if echo "$buffered_speed" | grep -q "GiB/s"; then
      disk_write_buffered_mb_s=$(echo "$buffered_speed" | sed 's/GiB\/s/ * 1024/' | bc 2>/dev/null || echo "0")
    else
      disk_write_buffered_mb_s=$(echo "$buffered_speed" | sed 's/MiB\/s//' | bc 2>/dev/null || echo "0")
    fi
    printf "${GREEN}✓${NC} Buffered write completed: ${buffered_speed}\n"
    printf "${GREEN}✓${NC} Test file created successfully: %s\n" "$TEST_FILE"
  else
    printf "${RED}✗${NC} Buffered write failed\n"
    return 1
  fi

  # Verify file was created
  if [ -f "$TEST_FILE" ]; then
    local file_size
    file_size=$(ls -lh "$TEST_FILE" | awk '{print $5}' || echo "unknown")
    printf "${BLUE}Test file info:${NC} %s (%s)\n" "$TEST_FILE" "$file_size"
  else
    printf "${RED}✗${NC} Test file was not created!\n"
    return 1
  fi

  # Sequential write direct I/O (fixed with both flags)
  log_section "Sequential Write (Direct I/O, 1GiB) -> ${TEST_FILE}"
  if dd if=/dev/zero of="$TEST_FILE" bs=1M count=1024 iflag=direct oflag=direct status=progress 2>&1; then
    local direct_speed
    direct_speed=$(dd if=/dev/zero of="$TEST_FILE" bs=1M count=1024 iflag=direct oflag=direct status=none 2>&1 | awk '/copied/ {print $(NF-1)}' | sed 's/ //g' || echo "0 MiB/s")
    # Convert to MB/s
    if echo "$direct_speed" | grep -q "GiB/s"; then
      disk_write_direct_mb_s=$(echo "$direct_speed" | sed 's/GiB\/s/ * 1024/' | bc 2>/dev/null || echo "0")
    else
      disk_write_direct_mb_s=$(echo "$direct_speed" | sed 's/MiB\/s//' | bc 2>/dev/null || echo "0")
    fi
    printf "${GREEN}✓${NC} Direct I/O write completed: ${direct_speed}\n"
  else
    printf "${YELLOW}Warning: Direct I/O write failed (may not be supported)${NC}\n"
  fi

  # Sequential read test
  log_section "Sequential Read (1GiB) <- ${TEST_FILE}"
  if dd if="$TEST_FILE" of=/dev/null bs=1M count=1024 iflag=direct status=progress 2>&1; then
    local read_speed
    read_speed=$(dd if="$TEST_FILE" of=/dev/null bs=1M count=1024 iflag=direct status=none 2>&1 | awk '/copied/ {print $(NF-1)}' | sed 's/ //g' || echo "0 MiB/s")
    # Convert to MB/s
    if echo "$read_speed" | grep -q "GiB/s"; then
      disk_read_mb_s=$(echo "$read_speed" | sed 's/GiB\/s/ * 1024/' | bc 2>/dev/null || echo "0")
    else
      disk_read_mb_s=$(echo "$read_speed" | sed 's/MiB\/s//' | bc 2>/dev/null || echo "0")
    fi
    printf "${GREEN}✓${NC} Read test completed: ${read_speed}\n"
  else
    printf "${YELLOW}Warning: Read test failed${NC}\n"
  fi

  # FIO random I/O tests for IOPS
  log_section "Random I/O (FIO - 4K blocks, 1GiB)"
  local fio_config
  fio_config="${SCRIPT_DIR}/fio_test.cfg"
  cat > "$fio_config" << 'EOF'
[global]
ioengine=libaio
direct=1
filename=pangolin_dd_testfile
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

  printf "${YELLOW}Running FIO random I/O test...${NC}\n"
  pushd "${SCRIPT_DIR}" >/dev/null
  local fio_output
  fio_output=$(fio "$fio_config" 2>&1 || echo "FIO test completed with errors")
  popd >/dev/null
  echo "${fio_output}" | grep -E "read:|write:|IOPS|BW=" || true
  rm -f "$fio_config"

  local file_size_used
  file_size_used=$(du -h "$TEST_FILE" 2>/dev/null | cut -f1 || echo 'unknown')
  log_summary "Disk Space Used" "$file_size_used"
}

if [ "$SKIP_DISK" = false ]; then
  disk_benchmark
fi

# Network Speed Test with IPv6 support and JSON parsing
network_benchmark() {
  log_section "Network Speed Test (${network_method}, IPv6: ${USE_IPV6})"
  local speedtest_output
  if command -v speedtest >/dev/null 2>&1; then
    # Ookla with IPv6 preference if requested
    if [ "$USE_IPV6" = true ]; then
      speedtest_output=$(speedtest --accept-license --accept-gdpr -f json --prefer-ipv6 2>/dev/null || speedtest --accept-license --accept-gdpr -f json)
    else
      speedtest_output=$(speedtest --accept-license --accept-gdpr -f json 2>/dev/null || speedtest --accept-license --accept-gdpr -f json)
    fi
  elif command -v speedtest-cli >/dev/null 2>&1; then
    # Python CLI - simple mode, no native IPv6 preference
    speedtest_output=$(speedtest-cli --simple --json 2>/dev/null || speedtest-cli --simple)
  else
    printf "${RED}No speedtest tool available${NC}\n"
    return 1
  fi

  if [ $? -ne 0 ]; then
    printf "${YELLOW}Warning: Network speed test failed${NC}\n"
    return 1
  fi

  # Parse JSON output if available
  if echo "${speedtest_output}" | jq . >/dev/null 2>&1; then
    download_speed_mbps=$(echo "${speedtest_output}" | jq -r '.download // .downloadSpeed' 2>/dev/null | awk '{print int($1/1000000)}' || echo "0")
    upload_speed_mbps=$(echo "${speedtest_output}" | jq -r '.upload // .uploadSpeed' 2>/dev/null | awk '{print int($1/1000000)}' || echo "0")
    ping_latency_ms=$(echo "${speedtest_output}" | jq -r '.ping // .pingLatency' 2>/dev/null || echo "0")
    echo "${speedtest_output}" | jq . || cat "${speedtest_output}"

    log_summary "Download" "${download_speed_mbps} Mbps"
    log_summary "Upload" "${upload_speed_mbps} Mbps"
    log_summary "Latency" "${ping_latency_ms} ms"
  else
    # Fallback to simple parsing for non-JSON output
    echo "${speedtest_output}"
    local dl_match ul_match lat_match
    dl_match=$(echo "${speedtest_output}" | grep -oP 'Download: \K\d+(?:\.?\d+)?' | head -1)
    ul_match=$(echo "${speedtest_output}" | grep -oP 'Upload: \K\d+(?:\.?\d+)?' | head -1)
    lat_match=$(echo "${speedtest_output}" | grep -oP 'Ping: \K\d+(?:\.?\d+)?' | head -1)

    download_speed_mbps="${dl_match:-0}"
    upload_speed_mbps="${ul_match:-0}"
    ping_latency_ms="${lat_match:-0}"
  fi

  printf "${GREEN}✓${NC} Network test complete\n"
}

if [ "$SKIP_NET" = false ] && [ "$network_method" != "none" ]; then
  network_benchmark
else
  printf "${YELLOW}Network test skipped${NC}\n"
fi

# Final summary and JSON output
log_info "Benchmark Summary"
if [ "$SKIP_CPU" = false ]; then
  log_summary "CPU (Single)" "${cpu_events_single} events/s"
  log_summary "CPU (Multi)" "${cpu_events_multi} events/s"
fi
if [ "$SKIP_DISK" = false ]; then
  log_summary "Disk Write (Buffered)" "${disk_write_buffered_mb_s} MB/s"
  log_summary "Disk Write (Direct)" "${disk_write_direct_mb_s} MB/s"
  log_summary "Disk Read" "${disk_read_mb_s} MB/s"
fi
if [ "$SKIP_NET" = false ] && [ "$network_method" != "none" ]; then
  log_summary "Download" "${download_speed_mbps} Mbps"
  log_summary "Upload" "${upload_speed_mbps} Mbps"
  log_summary "Ping" "${ping_latency_ms} ms"
fi

log_info "Benchmarking Complete"
printf "Test artifacts cleaned up. Results preserved in ${SUMMARY_FILE} if JSON enabled.\n"
printf "Test file location was: %s\n" "$TEST_FILE"
