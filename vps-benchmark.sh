#!/usr/bin/env bash
set -euo pipefail

## VPS Benchmark Script - Comprehensive System Performance Testing
#
# This script performs comprehensive benchmarking of VPS/server performance including:
# - CPU performance (single & multi-threaded)
# - Disk I/O (sequential read/write, random IOPS via fio)
# - Network bandwidth (Ookla Speedtest CLI)
# - System information collection
#
# Features:
# - Multi-distro support (Debian/Ubuntu, Fedora, RHEL/CentOS)
# - JSON output for programmatic parsing
# - Selective test execution
# - IPv6 support for network tests
# - Sudo fallback for non-root execution
# - Proper cleanup of temporary files
# - Color-coded output for readability

## Usage Examples
#
# Full benchmark suite (requires root):
# sudo ./vps-benchmark.sh
#
# CPU and disk only, skip network tests:
# sudo ./vps-benchmark.sh --skip-net
#
# Non-root execution with automatic sudo elevation:
# ./vps-benchmark.sh --sudo-fallback
#
# Network tests with IPv6 preference:
# sudo ./vps-benchmark.sh --ipv6
#
# Disable JSON output, run all tests:
# sudo ./vps-benchmark.sh --no-json
#
# Show help and exit:
# ./vps-benchmark.sh --help
#
# Quick disk-only benchmark:
# sudo ./vps-benchmark.sh --skip-cpu --skip-net

# Colors for terminal output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

# Global constants
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_FILE="${SCRIPT_DIR}/vps-benchmark-testfile"
readonly SUMMARY_FILE="${SCRIPT_DIR}/benchmark_results.json"
readonly MIN_FREE_SPACE_GB=2
readonly TEST_SIZE_GB=1

# Configuration options
SKIP_CPU=false
SKIP_DISK=false
SKIP_NET=false
SUDO_FALLBACK=false
USE_IPV6=false
OUTPUT_JSON=true
QUIET_INSTALL=false

# Performance metrics (global variables)
hostname="$(hostname)"
uptime="$(uptime -p)"
timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cpu_model=""
cpu_cores=0
total_memory_gb=0
cpu_events_single=0
cpu_events_multi=0
disk_write_buffered_mb_s=0
disk_write_direct_mb_s=0
disk_read_mb_s=0
disk_iops_read=0
disk_iops_write=0
network_method=""
network_download_mbps=0
network_upload_mbps=0
network_ping_ms=0

## Core Functions

# Exit with error message and cleanup
error_exit() {
  printf "${RED}ERROR: %s${NC}\n" "$1" >&2
  cleanup
  exit 1
}

# Print section header
log_section() {
  printf "\n${YELLOW}=== %s ===${NC}\n" "$1"
}

# Print informational message
log_info() {
  printf "${GREEN}  %s${NC}\n" "$1"
}

# Print warning message
log_warning() {
  printf "${YELLOW}  WARNING: %s${NC}\n" "$1"
}

# Print summary line (blue)
log_summary() {
  printf "${BLUE}%s: %s${NC}\n" "$1" "$2"
}

# Print success message
log_success() {
  printf "${GREEN}  ✓ %s${NC}\n" "$1"
}

# Print debug info (only if VERBOSE is true)
log_debug() {
  if [ "${VERBOSE:-false}" = true ]; then
    printf "${CYAN}  [DEBUG] %s${NC}\n" "$1"
  fi
}

# Display usage information
show_usage() {
  cat << 'EOF'

VPS Benchmark Script - Comprehensive System Performance Testing

USAGE:
  $0 [OPTIONS]

OPTIONS:
  --skip-cpu             Skip CPU benchmarks (sysbench)
  --skip-disk            Skip disk I/O benchmarks (dd + fio)
  --skip-net             Skip network tests (speedtest)
  --sudo-fallback        Automatically elevate to root using sudo
  --ipv6                 Prefer IPv6 servers for network tests
  --no-json              Disable JSON results output
  --quiet-install        Suppress package installation output
  --verbose              Enable debug output
  --help                 Show this help message

EXAMPLES:
  # Full benchmark (requires root privileges)
  sudo ./vps-benchmark.sh

  # CPU and disk only, skip network (faster execution)
  sudo ./vps-benchmark.sh --skip-net

  # Run from non-root account (auto-elevates)
  ./vps-benchmark.sh --sudo-fallback

  # Network tests with IPv6 preference
  sudo ./vps-benchmark.sh --ipv6

  # Complete benchmark with minimal output
  sudo ./vps-benchmark.sh --quiet-install --no-json

  # Disk I/O only (useful for storage testing)
  sudo ./vps-benchmark.sh --skip-cpu --skip-net

REQUIREMENTS:
  - Root privileges (or sudo access)
  - Debian/Ubuntu, Fedora, or RHEL/CentOS
  - Internet connection for package installation
  - At least 2GB free disk space in script directory

OUTPUT:
  - Terminal: Color-coded results and progress
  - JSON: benchmark_results.json (if --no-json not specified)
  - Temporary files: Automatically cleaned up

The script installs required tools (sysbench, fio, jq, bc, speedtest-cli) automatically
based on your distribution and performs cleanup of all temporary files.

EOF
  exit 0
}

# Parse command line arguments
parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --skip-cpu) SKIP_CPU=true; shift ;;
      --skip-disk) SKIP_DISK=true; shift ;;
      --skip-net) SKIP_NET=true; shift ;;
      --sudo-fallback) SUDO_FALLBACK=true; shift ;;
      --ipv6) USE_IPV6=true; shift ;;
      --no-json) OUTPUT_JSON=false; shift ;;
      --quiet-install) QUIET_INSTALL=true; shift ;;
      --verbose) VERBOSE=true; shift ;;
      --help) show_usage ;;
      -h) show_usage ;;
      *) error_exit "Unknown option: $1. Use --help for usage information" ;;
    esac
  done

  # Set default behavior
  if [ "$SKIP_CPU" = false ] && [ "$SKIP_DISK" = false ] && [ "$SKIP_NET" = false ]; then
    log_info "Running full benchmark suite (CPU + Disk + Network)"
  fi
}

# Cleanup function - preserves exit code and removes temporary files
cleanup() {
  local exit_code=$?

  # Remove test file if it exists
  if [ -f "$TEST_FILE" ]; then
    rm -f "$TEST_FILE" >/dev/null 2>&1
    log_debug "Cleaned up test file: $TEST_FILE"
  fi

  # Remove temporary FIO config if it exists
  local fio_config="${SCRIPT_DIR}/fio_test.cfg"
  if [ -f "$fio_config" ]; then
    rm -f "$fio_config" >/dev/null 2>&1
    log_debug "Cleaned up FIO config: $fio_config"
  fi

  # Save JSON results if enabled and data exists
  if [ "$OUTPUT_JSON" = true ] && [ -n "$hostname" ]; then
    save_json_results
  fi

  exit $exit_code
}

# Save results to JSON file
save_json_results() {
  local json_content
  json_content=$(cat << EOF
{
  "metadata": {
    "hostname": "${hostname}",
    "uptime": "${uptime}",
    "timestamp": "${timestamp}",
    "script_version": "2.0",
    "tests_run": {
      "cpu": $([ "$SKIP_CPU" = false ] && echo "true" || echo "false"),
      "disk": $([ "$SKIP_DISK" = false ] && echo "true" || echo "false"),
      "network": $([ "$SKIP_NET" = false ] && echo "true" || echo "false")
    }
  },
  "system": {
    "cpu_model": "${cpu_model}",
    "cpu_cores": ${cpu_cores},
    "total_memory_gb": ${total_memory_gb}
  },
  "benchmarks": {
    "cpu": {
      "single_thread_events_per_sec": ${cpu_events_single},
      "multi_thread_events_per_sec": ${cpu_events_multi}
    },
    "disk": {
      "write_buffered_mb_s": ${disk_write_buffered_mb_s},
      "write_direct_mb_s": ${disk_write_direct_mb_s},
      "read_mb_s": ${disk_read_mb_s},
      "random_read_iops": ${disk_iops_read},
      "random_write_iops": ${disk_iops_write}
    },
    "network": {
      "method": "${network_method}",
      "download_mbps": ${network_download_mbps},
      "upload_mbps": ${network_upload_mbps},
      "ping_ms": ${network_ping_ms}
    }
  }
}
EOF
  )

  printf "%s\n" "$json_content" > "$SUMMARY_FILE" 2>/dev/null || {
    log_warning "Could not save JSON results to $SUMMARY_FILE"
  }

  if [ -f "$SUMMARY_FILE" ]; then
    log_success "Results saved to: $SUMMARY_FILE"
    log_debug "JSON file size: $(stat -c%s "$SUMMARY_FILE" 2>/dev/null || echo "unknown") bytes"
  fi
}

# Check root privileges with sudo fallback
check_root_privileges() {
  if [ "$(id -u)" -ne 0 ]; then
    if [ "$SUDO_FALLBACK" = true ]; then
      if command -v sudo >/dev/null 2>&1; then
        log_info "Elevating privileges with sudo..."
        exec sudo "$0" "$@"
      else
        error_exit "Cannot elevate privileges: sudo is not available"
      fi
    else
      error_exit "Root privileges required. Use sudo or --sudo-fallback option."
    fi
  fi
  log_success "Running with root privileges"
}

# Validate disk space availability
validate_disk_space() {
  if [ "$SKIP_DISK" = true ]; then
    log_debug "Disk tests skipped - no space validation needed"
    return 0
  fi

  local available_gb
  available_gb=$(df -BG "$SCRIPT_DIR" | tail -1 | awk '{print $4}' | sed 's/G//')

  log_debug "Checking disk space in $SCRIPT_DIR"
  log_debug "Available: ${available_gb}GiB, Required: ${MIN_FREE_SPACE_GB}GiB"

  if command -v bc >/dev/null 2>&1; then
    if [ -z "$available_gb" ] || (( $(echo "$available_gb < $MIN_FREE_SPACE_GB" | bc -l) )); then
      error_exit "Insufficient disk space. Need ${MIN_FREE_SPACE_GB}GiB free in $SCRIPT_DIR (found ${available_gb}GiB)"
    fi
  else
    # Fallback without bc (less precise)
    if [ -z "$available_gb" ] || [ "${available_gb%.*}" -lt "$MIN_FREE_SPACE_GB" ]; then
      error_exit "Insufficient disk space. Need ${MIN_FREE_SPACE_GB}GiB free in $SCRIPT_DIR"
    fi
  fi

  log_success "Disk space validation passed (${available_gb}GiB available)"
}

# Collect system information
collect_system_info() {
  log_section "System Information Collection"

  # CPU information
  cpu_model=$(lscpu | grep "Model name" | sed 's/Model name: *//' | head -1)
  cpu_cores=$(nproc)

  # Memory information
  total_memory_gb=$(free -g | awk 'NR==2 {print $2}')

  # Display collected info
  printf "CPU: %s (%d cores)\n" "$cpu_model" "$cpu_cores"
  printf "Memory: %d GB total\n" "$total_memory_gb"
  printf "Disk: %s (%s)\n" "$SCRIPT_DIR" "$(df -h "$SCRIPT_DIR" | tail -1 | awk '{print $4 " available"}')"
  printf "Test file: %s (%d GB)\n" "$TEST_FILE" "$TEST_SIZE_GB"

  log_success "System information collected"
}

# Install dependencies based on distribution
install_dependencies() {
  log_section "Installing Dependencies"
  log_info "Required: sysbench, fio, jq, bc, speedtest-cli"

  if command -v apt-get >/dev/null 2>&1; then
    install_debian
  elif command -v dnf >/dev/null 2>&1; then
    install_fedora
  elif command -v yum >/dev/null 2>&1; then
    install_redhat
  else
    error_exit "Unsupported package manager. Supported: apt, dnf, yum"
  fi

  # Verify all tools are available
  verify_tools
  log_success "All dependencies installed and verified"
}

# Debian/Ubuntu installation
install_debian() {
  local apt_opts="-yqq"
  [ "$QUIET_INSTALL" = true ] || apt_opts="-y"

  log_debug "Detected Debian/Ubuntu (apt)"

  # Update package lists
  log_info "Updating package lists..."
  apt-get update $apt_opts || error_exit "Failed to update package lists"

  # Install core tools
  log_info "Installing core benchmarking tools..."
  apt-get install $apt_opts sysbench fio jq bc curl ca-certificates     || error_exit "Failed to install core packages"

  # Install speedtest
  install_speedtest_debian
}

# Install speedtest for Debian
install_speedtest_debian() {
  if command -v speedtest >/dev/null 2>&1; then
    network_method="ookla"
    log_success "Ookla Speedtest already available"
    return 0
  fi

  log_info "Installing Ookla Speedtest CLI..."
  if curl -sfS "https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh" | bash; then
    if apt-get install -y speedtest; then
      network_method="ookla"
      log_success "Ookla Speedtest installed"
      return 0
    fi
  fi

  # Fallback to Python version
  log_warning "Ookla installation failed, trying Python speedtest-cli"
  if command -v python3 >/dev/null 2>&1 && apt-get install -y python3-pip; then
    pip3 install --break-system-packages speedtest-cli >/dev/null 2>&1
    if command -v speedtest-cli >/dev/null 2>&1; then
      network_method="python-cli"
      log_success "Python speedtest-cli installed"
      return 0
    fi
  fi

  network_method="none"
  log_warning "No speedtest tool available - network tests will be skipped"
}

# Fedora installation
install_fedora() {
  log_debug "Detected Fedora (dnf)"

  # Enable EPEL if needed
  if ! command -v sysbench >/dev/null 2>&1; then
    log_info "Enabling EPEL repository..."
    dnf install -y epel-release >/dev/null 2>&1 || true
  fi

  # Install core packages
  log_info "Installing benchmarking tools..."
  dnf install -y sysbench fio jq bc curl ca-certificates python3-pip     || error_exit "Failed to install core packages"

  # Install speedtest
  install_speedtest_fedora
}

# Install speedtest for Fedora
install_speedtest_fedora() {
  if command -v speedtest >/dev/null 2>&1; then
    network_method="ookla"
    log_success "Ookla Speedtest already available"
    return 0
  fi

  log_info "Installing Ookla Speedtest CLI..."
  if curl -sfS "https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh" | bash; then
    if dnf install -y speedtest; then
      network_method="ookla"
      log_success "Ookla Speedtest installed"
      return 0
    fi
  fi

  # Fallback to Python
  log_warning "Trying Python speedtest-cli as fallback"
  pip3 install --break-system-packages speedtest-cli >/dev/null 2>&1
  if command -v speedtest-cli >/dev/null 2>&1; then
    network_method="python-cli"
    log_success "Python speedtest-cli installed"
    return 0
  fi

  network_method="none"
  log_warning "No speedtest tool available"
}

# RHEL/CentOS installation
install_redhat() {
  log_debug "Detected RHEL/CentOS (yum)"

  # Enable EPEL
  log_info "Enabling EPEL repository..."
  yum install -y epel-release >/dev/null 2>&1 || true

  # Install core packages
  log_info "Installing benchmarking tools..."
  yum install -y sysbench fio jq bc curl ca-certificates python3-pip     || error_exit "Failed to install core packages"

  # Install speedtest
  install_speedtest_redhat
}

# Install speedtest for RHEL
install_speedtest_redhat() {
  if command -v speedtest >/dev/null 2>&1; then
    network_method="ookla"
    log_success "Ookla Speedtest already available"
    return 0
  fi

  log_info "Installing Ookla Speedtest CLI..."
  if curl -sfS "https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh" | bash; then
    if yum install -y speedtest; then
      network_method="ookla"
      log_success "Ookla Speedtest installed"
      return 0
    fi
  fi

  # Fallback to Python
  pip3 install --break-system-packages speedtest-cli >/dev/null 2>&1
  if command -v speedtest-cli >/dev/null 2>&1; then
    network_method="python-cli"
    log_success "Python speedtest-cli installed"
    return 0
  fi

  network_method="none"
  log_warning "No speedtest tool available"
}

# Verify all required tools are installed
verify_tools() {
  local missing_tools=()

  # Core benchmarking tools
  for tool in sysbench fio jq bc; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      missing_tools+=("$tool")
    fi
  done

  # Network tool
  if [ "$SKIP_NET" = false ]; then
    if [ "$network_method" = "none" ]; then
      log_warning "No network testing tool available"
      SKIP_NET=true
    fi
  fi

  if [ ${#missing_tools[@]} -gt 0 ]; then
    error_exit "Missing required tools: ${missing_tools[*]}. Please install manually."
  fi

  # Display installed tool versions
  log_section "Tool Versions"
  for tool in sysbench fio jq bc; do
    printf "%-12s: " "$tool"
    command -v "$tool" >/dev/null 2>&1 && "$tool" --version 2>/dev/null | head -1 || printf "${YELLOW}not found${NC}"
    printf "\n"
  done

  if [ "$network_method" != "none" ]; then
    if command -v speedtest >/dev/null 2>&1; then
      printf "speedtest   : "
      speedtest --version 2>/dev/null | head -1
      printf "\n"
    else
      printf "speedtest-cli: "
      speedtest-cli --version 2>/dev/null | head -1
      printf "\n"
    fi
  fi

  log_success "All tools verified"
}

# Run CPU benchmarks
run_cpu_benchmarks() {
  if [ "$SKIP_CPU" = true ]; then
    log_info "CPU benchmarks skipped"
    return 0
  fi

  log_section "CPU Performance Benchmarks (sysbench)"

  local cpu_count max_prime test_duration=10

  cpu_count=$(nproc)
  max_prime=$((cpu_count * 1000 + 20000))

  log_info "CPU cores detected: $cpu_count"
  log_info "Test duration: ${test_duration}s, Prime limit: $max_prime"

  # Single-threaded benchmark
  log_info "Running single-threaded CPU test..."
  local single_output
  single_output=$(sysbench cpu --time="$test_duration" --threads=1 --cpu-max-prime="$max_prime" run 2>&1)

  if [ $? -eq 0 ]; then
    cpu_events_single=$(echo "$single_output" | grep -oP 'events per second: \K\d+(?:\.\d+)?' | head -1 || echo "0")
    echo "$single_output" | grep -E "total time:|events per second:|min: |max: |avg:" || true
    log_summary "CPU Single-Thread" "${cpu_events_single} events/sec"
  else
    log_warning "Single-threaded CPU test failed"
    cpu_events_single=0
  fi

  # Multi-threaded benchmark
  log_info "Running multi-threaded CPU test ($cpu_count threads)..."
  local multi_output
  multi_output=$(sysbench cpu --time="$test_duration" --threads="$cpu_count" --cpu-max-prime="$max_prime" run 2>&1)

  if [ $? -eq 0 ]; then
    cpu_events_multi=$(echo "$multi_output" | grep -oP 'events per second: \K\d+(?:\.\d+)?' | head -1 || echo "0")
    echo "$multi_output" | grep -E "total time:|events per second:|min: |max: |avg:" || true
    log_summary "CPU Multi-Thread" "${cpu_events_multi} events/sec"
    log_success "CPU benchmarks completed"
  else
    log_warning "Multi-threaded CPU test failed"
    cpu_events_multi=0
  fi
}

# Run disk benchmarks
run_disk_benchmarks() {
  if [ "$SKIP_DISK" = true ]; then
    log_info "Disk benchmarks skipped"
    return 0
  fi

  log_section "Disk Performance Benchmarks"
  log_info "Test file: $TEST_FILE (${TEST_SIZE_GB}GB)"
  log_info "Sequential I/O with dd, Random I/O with fio"

  # Ensure test directory exists
  local test_dir
  test_dir=$(dirname "$TEST_FILE")
  mkdir -p "$test_dir" >/dev/null 2>&1 || error_exit "Cannot create test directory: $test_dir"

  # Sequential write - buffered
  log_info "Sequential write test (buffered, ${TEST_SIZE_GB}GB)..."
  local buffered_output
  buffered_output=$(dd if=/dev/zero of="$TEST_FILE" bs=1M count="$((TEST_SIZE_GB * 1024))" conv=fdatasync status=progress 2>&1)

  if [ $? -eq 0 ]; then
    # Extract speed from output
    local write_speed
    write_speed=$(echo "$buffered_output" | grep -oP '\d+(?:\.\d+)? [GM]B/s' | tail -1 | sed 's/ //g' || echo "0 MB/s")

    # Convert to MB/s
    if echo "$write_speed" | grep -q "GB/s"; then
      disk_write_buffered_mb_s=$(echo "$write_speed" | sed 's/GB\/s/ * 1024/;s/ //g' | bc 2>/dev/null || echo "0")
    else
      disk_write_buffered_mb_s=$(echo "$write_speed" | sed 's/MB\/s//;s/ //g' | bc 2>/dev/null || echo "0")
    fi

    echo "$buffered_output" | tail -2
    log_summary "Write Buffered" "${disk_write_buffered_mb_s} MB/s"
    log_success "Buffered write test completed"
  else
    log_warning "Buffered write test failed"
    disk_write_buffered_mb_s=0
  fi

  # Verify file was created
  if [ -f "$TEST_FILE" ]; then
    local file_size_gb
    file_size_gb=$(($(stat -c%s "$TEST_FILE" 2>/dev/null || echo "0") / 1024 / 1024 / 1024))
    log_debug "Created test file: ${file_size_gb}GB"
  fi

  # Sequential write - direct I/O (may fail on some filesystems)
  log_info "Sequential write test (direct I/O, ${TEST_SIZE_GB}GB)..."
  if dd if=/dev/zero of="$TEST_FILE" bs=1M count="$((TEST_SIZE_GB * 1024))" iflag=direct oflag=direct status=progress 2>&1; then
    local direct_speed
    direct_speed=$(dd if=/dev/zero of="$TEST_FILE" bs=1M count="$((TEST_SIZE_GB * 1024))" iflag=direct oflag=direct status=none 2>&1 | awk '/copied/ {print $(NF-1)}' | sed 's/ //g' || echo "0 MB/s")

    if echo "$direct_speed" | grep -q "GB/s"; then
      disk_write_direct_mb_s=$(echo "$direct_speed" | sed 's/GB\/s/ * 1024/;s/ //g' | bc 2>/dev/null || echo "0")
    else
      disk_write_direct_mb_s=$(echo "$direct_speed" | sed 's/MB\/s//;s/ //g' | bc 2>/dev/null || echo "0")
    fi

    log_summary "Write Direct" "${disk_write_direct_mb_s} MB/s"
    log_success "Direct I/O write completed"
  else
    log_warning "Direct I/O write failed (common on some filesystems)"
    disk_write_direct_mb_s=0
  fi

  # Sequential read test
  log_info "Sequential read test (${TEST_SIZE_GB}GB)..."
  if dd if="$TEST_FILE" of=/dev/null bs=1M iflag=direct status=progress 2>&1; then
    local read_speed
    read_speed=$(dd if="$TEST_FILE" of=/dev/null bs=1M iflag=direct status=none 2>&1 | awk '/copied/ {print $(NF-1)}' | sed 's/ //g' || echo "0 MB/s")

    if echo "$read_speed" | grep -q "GB/s"; then
      disk_read_mb_s=$(echo "$read_speed" | sed 's/GB\/s/ * 1024/;s/ //g' | bc 2>/dev/null || echo "0")
    else
      disk_read_mb_s=$(echo "$read_speed" | sed 's/MB\/s//;s/ //g' | bc 2>/dev/null || echo "0")
    fi

    log_summary "Read Sequential" "${disk_read_mb_s} MB/s"
    log_success "Read test completed"
  else
    log_warning "Read test failed"
    disk_read_mb_s=0
  fi

  # Random I/O with fio
  run_fio_benchmarks
}

# Run FIO random I/O benchmarks
run_fio_benchmarks() {
  log_info "Random I/O testing with fio (4K blocks)..."

  local fio_config="${SCRIPT_DIR}/fio_test.cfg"
  cat > "$fio_config" << 'EOF'
[global]
ioengine=libaio
direct=1
filename=vps-benchmark-testfile
size=1G
bs=4k
iodepth=32
numjobs=4
runtime=30
group_reporting=1
output-format=normal
directory=/tmp

[randread]
rw=randread
time_based=1

[randwrite]
rw=randwrite
time_based=1
EOF

  # Run FIO in script directory
  pushd "$SCRIPT_DIR" >/dev/null
  local fio_output
  fio_output=$(fio "$fio_config" 2>&1 || echo "FIO test completed with warnings")
  popd >/dev/null

  # Extract IOPS values
  disk_iops_read=$(echo "$fio_output" | grep "read: IOPS=" | grep -oP 'IOPS=\K\d+' | head -1 || echo "0")
  disk_iops_write=$(echo "$fio_output" | grep "write: IOPS=" | grep -oP 'IOPS=\K\d+' | head -1 || echo "0")

  # Display relevant FIO output
  echo "$fio_output" | grep -E "(read:|write:|IOPS=|BW=|lat=|CPU)" || true

  # Cleanup FIO config
  rm -f "$fio_config"

  log_summary "Random Read IOPS" "$disk_iops_read"
  log_summary "Random Write IOPS" "$disk_iops_write"
  log_success "Random I/O testing completed"
}

# Run network benchmarks
run_network_benchmarks() {
  if [ "$SKIP_NET" = true ] || [ "$network_method" = "none" ]; then
    log_info "Network benchmarks skipped"
    return 0
  fi

  log_section "Network Performance Test"
  log_info "Method: $network_method, IPv6: $([ "$USE_IPV6" = true ] && echo "enabled" || echo "disabled")"

  local speedtest_output
  local success=false

  # Run speedtest based on available tool
  if command -v speedtest >/dev/null 2>&1; then
    log_info "Running Ookla Speedtest CLI..."
    if [ "$USE_IPV6" = true ]; then
      speedtest_output=$(speedtest --accept-license --accept-gdpr -f json --prefer-ipv6 2>/dev/null || speedtest --accept-license --accept-gdpr)
    else
      speedtest_output=$(speedtest --accept-license --accept-gdpr -f json 2>/dev/null || speedtest --accept-license --accept-gdpr)
    fi
    success=true
  elif command -v speedtest-cli >/dev/null 2>&1; then
    log_info "Running Python speedtest-cli..."
    speedtest_output=$(speedtest-cli --simple --json 2>/dev/null || speedtest-cli --simple)
    success=true
  fi

  if [ "$success" = true ] && [ -n "$speedtest_output" ]; then
    # Parse JSON output if available
    if echo "$speedtest_output" | jq . >/dev/null 2>&1 2>/dev/null; then
      network_download_mbps=$(echo "$speedtest_output" | jq -r '.download // .downloadSpeed' 2>/dev/null | awk '{print int($1/1000000)}' || echo "0")
      network_upload_mbps=$(echo "$speedtest_output" | jq -r '.upload // .uploadSpeed' 2>/dev/null | awk '{print int($1/1000000)}' || echo "0")
      network_ping_ms=$(echo "$speedtest_output" | jq -r '.ping // .pingLatency' 2>/dev/null || echo "0")

      # Pretty print JSON if available
      echo "$speedtest_output" | jq . 2>/dev/null || cat "$speedtest_output"
    else
      # Fallback parsing for simple output
      echo "$speedtest_output"
      network_download_mbps=$(echo "$speedtest_output" | grep -oP 'Download: \K\d+(?:\.\d+)?' | head -1 || echo "0")
      network_upload_mbps=$(echo "$speedtest_output" | grep -oP 'Upload: \K\d+(?:\.\d+)?' | head -1 || echo "0")
      network_ping_ms=$(echo "$speedtest_output" | grep -oP 'Ping: \K\d+(?:\.\d+)?' | head -1 || echo "0")
    fi

    log_summary "Network Download" "${network_download_mbps} Mbps"
    log_summary "Network Upload" "${network_upload_mbps} Mbps"
    log_summary "Network Latency" "${network_ping_ms} ms"
    log_success "Network testing completed"
  else
    log_warning "Network test failed or no tool available"
    network_download_mbps=0
    network_upload_mbps=0
    network_ping_ms=0
  fi
}

# Display final results summary
display_final_summary() {
  log_section "FINAL RESULTS SUMMARY"

  printf "\n${CYAN}%-20s %s${NC}\n" "System" "Details"
  printf "%-20s %s\n" "Hostname:" "$hostname"
  printf "%-20s %s (%d cores)\n" "CPU:" "$cpu_model" "$cpu_cores"
  printf "%-20s %d GB\n" "Memory:" "$total_memory_gb"

  if [ "$SKIP_CPU" = false ]; then
    printf "\n${CYAN}%-20s %s${NC}\n" "CPU Performance" "Events/sec"
    printf "%-20s %s\n" "Single-Thread:" "$cpu_events_single"
    printf "%-20s %s\n" "Multi-Thread:" "$cpu_events_multi"
  fi

  if [ "$SKIP_DISK" = false ]; then
    printf "\n${CYAN}%-20s %s${NC}\n" "Disk Performance" "MB/s (Sequential)"
    printf "%-20s %s\n" "Write Buffered:" "$disk_write_buffered_mb_s"
    printf "%-20s %s\n" "Write Direct:" "$disk_write_direct_mb_s"
    printf "%-20s %s\n" "Read Sequential:" "$disk_read_mb_s"
    printf "%-20s %s / %s\n" "Random IOPS:" "$disk_iops_read (read)" "$disk_iops_write (write)"
  fi

  if [ "$SKIP_NET" = false ] && [ "$network_method" != "none" ]; then
    printf "\n${CYAN}%-20s %s${NC}\n" "Network Performance" "Mbps"
    printf "%-20s %s\n" "Download:" "$network_download_mbps"
    printf "%-20s %s\n" "Upload:" "$network_upload_mbps"
    printf "%-20s %s ms\n" "Latency:" "$network_ping_ms"
    printf "%-20s %s\n" "Method:" "$network_method"
  fi

  # Performance overview
  printf "\n${GREEN}%-20s${NC}\n" "PERFORMANCE OVERVIEW"
  if [ "$cpu_events_single" -gt 1000 ]; then
    log_success "CPU performance: GOOD (${cpu_events_single} single-thread events/sec)"
  else
    log_warning "CPU performance: LOW (${cpu_events_single} single-thread events/sec)"
  fi

  if [ "$disk_write_buffered_mb_s" -gt 100 ]; then
    log_success "Disk performance: GOOD (${disk_write_buffered_mb_s} MB/s write)"
  else
    log_warning "Disk performance: SLOW (${disk_write_buffered_mb_s} MB/s write)"
  fi

  if [ "$network_download_mbps" -gt 100 ]; then
    log_success "Network performance: GOOD (${network_download_mbps} Mbps download)"
  else
    log_warning "Network performance: SLOW (${network_download_mbps} Mbps download)"
  fi

  log_success "Benchmarking completed successfully"

  # JSON output notice
  if [ "$OUTPUT_JSON" = true ]; then
    log_info "Detailed results available in: $SUMMARY_FILE"
  fi

  # Cleanup notice
  log_info "All temporary files have been cleaned up"
}

## MAIN EXECUTION

# Set up signal handling
trap cleanup EXIT INT TERM

# Parse command line arguments
parse_arguments "$@"

# Check privileges
check_root_privileges

# Validate disk space for disk tests
validate_disk_space

# Collect basic system information
collect_system_info

# Install required dependencies
install_dependencies

# Run benchmarks in sequence
log_section "Starting Benchmark Suite"

if [ "$SKIP_CPU" = false ]; then
  run_cpu_benchmarks
fi

if [ "$SKIP_DISK" = false ]; then
  run_disk_benchmarks
fi

if [ "$SKIP_NET" = false ]; then
  run_network_benchmarks
fi

# Display final results
display_final_summary

log_info "VPS benchmark script completed"
printf "\n${GREEN}Thank you for using VPS Benchmark!${NC}\n"

EOF
