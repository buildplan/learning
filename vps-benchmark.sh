#!/usr/bin/env bash
set -euo pipefail

## VPS Benchmark Script
# Benchmarks CPU (sysbench), disk (dd + fio), and network (Ookla Speedtest CLI).
# Outputs colorized console results and JSON (benchmark_results.json).
#
# Requirements:
# - Linux (Debian/Ubuntu, Fedora, or RHEL/CentOS)
# - Root or sudo for package installs (sysbench, fio, jq, bc, speedtest)
#
# Quick start:
#   sudo ./vps-benchmark.sh
#
# Common options:
#   --skip-cpu            Skip CPU tests
#   --skip-disk           Skip disk tests
#   --skip-net            Skip network tests
#   --disk-path PATH      Directory to write 1GiB test file (default: script dir)
#   --ipv6                Prefer IPv6 for speedtest servers
#   --sudo-fallback       Re-exec with sudo if not root
#   --no-json             Disable JSON output
#   --quiet-install       Quieter apt/dnf/yum output
#   --verbose             Debug logging
#
# Examples:
#   sudo ./vps-benchmark.sh --skip-net
#   ./vps-benchmark.sh --sudo-fallback --disk-path /mnt/fast
#   sudo ./vps-benchmark.sh --ipv6 --quiet-install
#
# Notes:
# - CPU uses sysbench cpu --time 10 --cpu-max-prime 20000; compare “events per second”. [web:11][web:8]
# - Disk runs 1GiB sequential buffered and direct I/O writes plus direct read; random 4k IOPS via fio. [web:31][web:25]
# - Ookla JSON: download/upload bandwidth is bytes/s; Mbps = bandwidth/125000; ping/jitter in ms. [web:21][web:18]

# Colors
esc=$'\033'
RED="${esc}[0;31m"; GREEN="${esc}[0;32m"; YELLOW="${esc}[1;33m"; BLUE="${esc}[0;34m"; CYAN="${esc}[0;36m"; NC="${esc}[0m"

# Globals
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISK_PATH="${DISK_PATH:-$SCRIPT_DIR}" # override with env or --disk-path
TEST_FILE="${DISK_PATH%/}/vps-benchmark-testfile"
SUMMARY_FILE="${SCRIPT_DIR}/benchmark_results.json"
MIN_FREE_SPACE_GB=2
TEST_SIZE_GB=1

# Config
SKIP_CPU=false
SKIP_DISK=false
SKIP_NET=false
SUDO_FALLBACK=false
USE_IPV6=false
OUTPUT_JSON=true
QUIET_INSTALL=false
VERBOSE=false

# Metrics
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
network_jitter_ms=0
network_packet_loss=0

# Logging
error_exit(){ printf "${RED}ERROR: %s${NC}\n" "$1" >&2; cleanup; exit 1; }
log_section(){ printf "\n${YELLOW}=== %s ===${NC}\n" "$1"; }
log_info(){ printf "${GREEN}  %s${NC}\n" "$1"; }
log_warning(){ printf "${YELLOW}  WARNING: %s${NC}\n" "$1"; }
log_summary(){ printf "${BLUE}%s: %s${NC}\n" "$1" "$2"; }
log_success(){ printf "${GREEN}  ✓ %s${NC}\n" "$1"; }
log_debug(){ [ "$VERBOSE" = true ] && printf "${CYAN}  [DEBUG] %s${NC}\n" "$1"; }

show_usage(){
  cat <<'EOF'
VPS Benchmark Script

USAGE:
  vps-benchmark.sh [OPTIONS]

OPTIONS:
  --skip-cpu             Skip CPU (sysbench)
  --skip-disk            Skip disk (dd + fio)
  --skip-net             Skip network (speedtest)
  --sudo-fallback        Elevate with sudo if not root
  --ipv6                 Prefer IPv6 for speedtest
  --no-json              Disable JSON results
  --quiet-install        Suppress install output
  --verbose              Debug logging
  --disk-path PATH       Directory for test file (default: script dir)
  --help, -h             Show this help
EOF
  exit 0
}

parse_arguments(){
  while [[ $# -gt 0 ]]; do
    case $1 in
      --skip-cpu) SKIP_CPU=true; shift;;
      --skip-disk) SKIP_DISK=true; shift;;
      --skip-net) SKIP_NET=true; shift;;
      --sudo-fallback) SUDO_FALLBACK=true; shift;;
      --ipv6) USE_IPV6=true; shift;;
      --no-json) OUTPUT_JSON=false; shift;;
      --quiet-install) QUIET_INSTALL=true; shift;;
      --verbose) VERBOSE=true; shift;;
      --disk-path) DISK_PATH="$2"; TEST_FILE="${DISK_PATH%/}/vps-benchmark-testfile"; shift 2;;
      --help|-h) show_usage;;
      *) error_exit "Unknown option: $1 (use --help)";;
    esac
  done
  if [ "$SKIP_CPU" = false ] && [ "$SKIP_DISK" = false ] && [ "$SKIP_NET" = false ]; then
    log_info "Running full benchmark suite (CPU + Disk + Network)"
  fi
}

cleanup(){
  local exit_code=$?
  rm -f "$TEST_FILE" 2>/dev/null || true
  rm -f "${SCRIPT_DIR}/fio_test.cfg" 2>/dev/null || true
  if [ "$OUTPUT_JSON" = true ] && [ -n "${hostname:-}" ]; then
    save_json_results
  fi
  exit $exit_code
}

save_json_results(){
  cat > "$SUMMARY_FILE" <<EOF
{
  "metadata": {
    "hostname": "${hostname}",
    "uptime": "${uptime}",
    "timestamp": "${timestamp}",
    "script_version": "2.2",
    "tests_run": {
      "cpu": $([ "$SKIP_CPU" = false ] && echo true || echo false),
      "disk": $([ "$SKIP_DISK" = false ] && echo true || echo false),
      "network": $([ "$SKIP_NET" = false ] && echo true || echo false)
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
      "ping_ms": ${network_ping_ms},
      "jitter_ms": ${network_jitter_ms},
      "packet_loss": ${network_packet_loss}
    }
  }
}
EOF
  if [ -f "$SUMMARY_FILE" ]; then
    log_success "Results saved to: $SUMMARY_FILE"
  else
    log_warning "Could not save JSON results to $SUMMARY_FILE"
  fi
}

check_root_privileges(){
  if [ "$(id -u)" -ne 0 ]; then
    if [ "$SUDO_FALLBACK" = true ] && command -v sudo >/dev/null 2>&1; then
      log_info "Elevating privileges with sudo..."
      exec sudo -- "$0" "$@"
    else
      error_exit "Root privileges required. Use sudo or --sudo-fallback."
    fi
  fi
  log_success "Running with root privileges"
}

validate_disk_space(){
  [ "$SKIP_DISK" = true ] && { log_debug "Disk tests skipped"; return; }
  mkdir -p "$DISK_PATH" || error_exit "Cannot create disk path: $DISK_PATH"
  local available_gb
  available_gb=$(df -BG "$DISK_PATH" | tail -1 | awk '{print $4}' | sed 's/G//')
  log_debug "Disk path: $DISK_PATH; Available: ${available_gb}GiB; Required: ${MIN_FREE_SPACE_GB}GiB"
  if [ -z "$available_gb" ] || [ "${available_gb%.*}" -lt "$MIN_FREE_SPACE_GB" ]; then
    error_exit "Insufficient disk space in $DISK_PATH (need ${MIN_FREE_SPACE_GB}GiB)"
  fi
  log_success "Disk space validation passed (${available_gb}GiB available)"
}

collect_system_info(){
  log_section "System Information"
  cpu_model=$(lscpu 2>/dev/null | awk -F: '/Model name/ {sub(/^ +/,"",$2); print $2; exit}')
  cpu_cores=$(nproc 2>/dev/null || echo 1)
  total_memory_gb=$(free -g 2>/dev/null | awk 'NR==2 {print $2+0}')
  printf "CPU: %s (%d cores)\n" "${cpu_model:-Unknown}" "$cpu_cores"
  printf "Memory: %d GB total\n" "$total_memory_gb"
  printf "Disk path: %s (%s available)\n" "$DISK_PATH" "$(df -h "$DISK_PATH" | tail -1 | awk '{print $4}')"
  printf "Test file: %s (%d GB)\n" "$TEST_FILE" "$TEST_SIZE_GB"
  log_success "System information collected"
}

install_dependencies(){
  log_section "Installing Dependencies"
  log_info "Required: sysbench, fio, jq, bc, speedtest (Ookla preferred)"
  if command -v apt-get >/dev/null 2>&1; then
    install_debian
  elif command -v dnf >/dev/null 2>&1; then
    install_fedora
  elif command -v yum >/dev/null 2>&1; then
    install_redhat
  else
    error_exit "Unsupported package manager (apt/dnf/yum)"
  fi
  verify_tools
  log_success "All dependencies installed and verified"
}

install_debian(){
  local apt_opts="-y"
  [ "$QUIET_INSTALL" = true ] && apt_opts="-yqq"
  apt-get update $apt_opts
  apt-get install $apt_opts sysbench fio jq bc curl ca-certificates
  install_speedtest_debian
}

install_speedtest_debian(){
  if command -v speedtest >/dev/null 2>&1; then network_method="ookla"; return; fi
  if curl -fsSL "https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh" | bash; then
    if apt-get install -y speedtest; then network_method="ookla"; return; fi
  fi
  if command -v python3 >/dev/null 2>&1; then
    apt-get install -y python3-pip || true
    pip3 install --break-system-packages speedtest-cli || true
    if command -v speedtest-cli >/dev/null 2>&1; then network_method="python-cli"; return; fi
  fi
  network_method="none"
}

install_fedora(){
  dnf -y install epel-release || true
  dnf -y install sysbench fio jq bc curl ca-certificates python3-pip
  install_speedtest_fedora
}

install_speedtest_fedora(){
  if command -v speedtest >/dev/null 2>&1; then network_method="ookla"; return; fi
  if curl -fsSL "https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh" | bash; then
    if dnf -y install speedtest; then network_method="ookla"; return; fi
  fi
  pip3 install --break-system-packages speedtest-cli || true
  if command -v speedtest-cli >/dev/null 2>&1; then network_method="python-cli"; else network_method="none"; fi
}

install_redhat(){
  yum -y install epel-release || true
  yum -y install sysbench fio jq bc curl ca-certificates python3-pip
  install_speedtest_redhat
}

install_speedtest_redhat(){
  if command -v speedtest >/dev/null 2>&1; then network_method="ookla"; return; fi
  if curl -fsSL "https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh" | bash; then
    if yum -y install speedtest; then network_method="ookla"; return; fi
  fi
  pip3 install --break-system-packages speedtest-cli || true
  if command -v speedtest-cli >/dev/null 2>&1; then network_method="python-cli"; else network_method="none"; fi
}

verify_tools(){
  local missing=()
  for t in sysbench fio jq bc; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if [ "$SKIP_NET" = false ] && [ "${network_method:-none}" = "none" ]; then
    log_warning "No network test tool available; skipping network tests"
    SKIP_NET=true
  fi
  if [ ${#missing[@]} -gt 0 ]; then
    error_exit "Missing required tools: ${missing[*]}"
  fi

  log_section "Tool Versions"
  for t in sysbench fio jq bc; do
    printf "%-12s: " "$t"
    "$t" --version 2>/dev/null | head -1 || echo "unknown"
  done
  if [ "${network_method:-none}" != "none" ]; then
    if command -v speedtest >/dev/null 2>&1; then
      printf "speedtest   : "
      speedtest --version 2>/dev/null | head -1
    fi
    if command -v speedtest-cli >/dev/null 2>&1; then
      printf "speedtest-cli: "
      speedtest-cli --version 2>/dev/null | head -1
    fi
  fi
  log_success "All tools verified"
}

run_cpu_benchmarks(){
  [ "$SKIP_CPU" = true ] && { log_info "CPU benchmarks skipped"; return; }
  log_section "CPU Performance (sysbench)"
  local cpu_count test_duration=10 max_prime=20000
  cpu_count=$(nproc 2>/dev/null || echo 1)
  log_info "Threads: single and ${cpu_count}; time: ${test_duration}s; max-prime: ${max_prime}"

  local out1
  if out1=$(sysbench cpu --time="$test_duration" --threads=1 --cpu-max-prime="$max_prime" run 2>&1); then
    cpu_events_single=$(echo "$out1" | awk -F': ' '/events per second:/ {print $2; exit}')
    echo "$out1" | grep -E "total time:|events per second:|min: |max: |avg:" || true
    log_summary "CPU Single-Thread" "${cpu_events_single} events/sec"
  else
    log_warning "Single-thread CPU test failed"; cpu_events_single=0
  fi

  local outn
  if outn=$(sysbench cpu --time="$test_duration" --threads="$cpu_count" --cpu-max-prime="$max_prime" run 2>&1); then
    cpu_events_multi=$(echo "$outn" | awk -F': ' '/events per second:/ {print $2; exit}')
    echo "$outn" | grep -E "total time:|events per second:|min: |max: |avg:" || true
    log_summary "CPU Multi-Thread" "${cpu_events_multi} events/sec"
    log_success "CPU benchmarks completed"
  else
    log_warning "Multi-thread CPU test failed"; cpu_events_multi=0
  fi
  # events/sec is the stable comparator with fixed time and max-prime. [web:11][web:8]
}

# Parse "123 MB/s" or "1.2 GB/s" to integer MB/s
rate_to_mb(){
  local rate="$1" num unit
  num=$(echo "$rate" | awk '{print $1}')
  unit=$(echo "$rate" | awk '{print $2}')
  if [[ "$unit" == "GB/s" ]]; then
    awk -v n="$num" 'BEGIN{printf "%d", n*1024}'
  else
    awk -v n="$num" 'BEGIN{printf "%d", n}'
  fi
}

run_disk_benchmarks(){
  [ "$SKIP_DISK" = true ] && { log_info "Disk benchmarks skipped"; return; }
  log_section "Disk Performance"
  log_info "Path: $DISK_PATH; Test file: $TEST_FILE; Size: ${TEST_SIZE_GB}GiB"
  mkdir -p "$DISK_PATH"

  log_info "Sequential write (buffered + fdatasync, ${TEST_SIZE_GB}GiB)"
  local out_buf rate_buf
  out_buf=$({ dd if=/dev/zero of="$TEST_FILE" bs=1M count="$((TEST_SIZE_GB*1024))" conv=fdatasync status=progress; } 2>&1 || true)
  rate_buf=$(printf "%s\n" "$out_buf" | grep -Eo '[0-9]+(\.[0-9]+)? [GM]B/s' | tail -1 || true)
  if [ -n "$rate_buf" ]; then
    disk_write_buffered_mb_s=$(rate_to_mb "$rate_buf")
    echo "$out_buf" | tail -2
    log_summary "Write Buffered" "${disk_write_buffered_mb_s} MB/s"
  else
    log_warning "Buffered write parsing failed"; disk_write_buffered_mb_s=0
  fi

  log_info "Sequential write (direct I/O, ${TEST_SIZE_GB}GiB)"
  local out_dir rate_dir
  out_dir=$({ dd if=/dev/zero of="$TEST_FILE" bs=1M count="$((TEST_SIZE_GB*1024))" oflag=direct status=progress; } 2>&1 || true)
  rate_dir=$(printf "%s\n" "$out_dir" | grep -Eo '[0-9]+(\.[0-9]+)? [GM]B/s' | tail -1 || true)
  if [ -n "$rate_dir" ]; then
    disk_write_direct_mb_s=$(rate_to_mb "$rate_dir")
    echo "$out_dir" | tail -2
    log_summary "Write Direct" "${disk_write_direct_mb_s} MB/s"
  else
    log_warning "Direct write failed or parsing failed"; disk_write_direct_mb_s=0
  fi

  if [ -f "$TEST_FILE" ]; then
    log_info "Sequential read (direct I/O, ${TEST_SIZE_GB}GiB)"
    local out_read rate_read
    out_read=$({ dd if="$TEST_FILE" of=/dev/null bs=1M iflag=direct status=progress; } 2>&1 || true)
    rate_read=$(printf "%s\n" "$out_read" | grep -Eo '[0-9]+(\.[0-9]+)? [GM]B/s' | tail -1 || true)
    if [ -n "$rate_read" ]; then
      disk_read_mb_s=$(rate_to_mb "$rate_read")
      echo "$out_read" | tail -2
      log_summary "Read Sequential" "${disk_read_mb_s} MB/s"
    else
      log_warning "Read parsing failed"; disk_read_mb_s=0
    fi
  fi

  run_fio_benchmarks
}

run_fio_benchmarks(){
  log_info "Random I/O (fio, 4k, direct=1, iodepth=32, numjobs=4, 30s)"
  local fio_cfg="${SCRIPT_DIR}/fio_test.cfg"
  cat > "$fio_cfg" <<'EOF'
[global]
ioengine=libaio
direct=1
filename=vps-benchmark-testfile
size=1G
bs=4k
iodepth=32
numjobs=4
runtime=30
time_based=1
group_reporting=1
output-format=normal

[randread]
rw=randread

[randwrite]
rw=randwrite
EOF
  (cd "$DISK_PATH" && fio "$fio_cfg") > "${SCRIPT_DIR}/fio_output.txt" 2>&1 || true
  local fio_output
  fio_output="$(cat "${SCRIPT_DIR}/fio_output.txt" 2>/dev/null || true)"
  # Aggregate totals (group_reporting) [web:31][web:25]
  disk_iops_read=$(echo "$fio_output" | awk -F'[=, ]+' '/read: .*IOPS=/{for(i=1;i<=NF;i++) if($i=="IOPS"){print $(i+1); exit}}' | sed 's/[^0-9].*$//')
  disk_iops_write=$(echo "$fio_output" | awk -F'[=, ]+' '/write: .*IOPS=/{for(i=1;i<=NF;i++) if($i=="IOPS"){print $(i+1); exit}}' | sed 's/[^0-9].*$//')
  disk_iops_read=${disk_iops_read:-0}; disk_iops_write=${disk_iops_write:-0}
  echo "$fio_output" | grep -E "(read:|write:|IOPS=|BW=|lat=|CPU)" || true
  log_summary "Random Read IOPS" "$disk_iops_read"
  log_summary "Random Write IOPS" "$disk_iops_write"
  rm -f "$fio_cfg" "${SCRIPT_DIR}/fio_output.txt" || true
  log_success "Random I/O testing completed"
}

run_network_benchmarks(){
  [ "$SKIP_NET" = true ] && { log_info "Network benchmarks skipped"; return; }
  if [ "${network_method:-none}" = "none" ]; then log_info "No network tool available"; return; fi
  log_section "Network Performance (Speedtest)"
  log_info "Method: $network_method; IPv6: $([ "$USE_IPV6" = true ] && echo enabled || echo disabled)"

  local speedtest_output=""
  if [ "$network_method" = "ookla" ] && command -v speedtest >/dev/null 2>&1; then
    if [ "$USE_IPV6" = true ]; then
      speedtest_output=$(speedtest --accept-license --accept-gdpr -f json --prefer-ipv6 || true)
    else
      speedtest_output=$(speedtest --accept-license --accept-gdpr -f json || true)
    fi
    if [ -n "$speedtest_output" ] && echo "$speedtest_output" | jq . >/dev/null 2>&1; then
      # bandwidth bytes/s -> Mbps = /125000 [web:21][web:18]
      local dn_bw up_bw
      dn_bw=$(echo "$speedtest_output" | jq -r '.download.bandwidth // .download // 0')
      up_bw=$(echo "$speedtest_output" | jq -r '.upload.bandwidth   // .upload   // 0')
      network_download_mbps=$(awk -v b="$dn_bw" 'BEGIN{printf "%d", (b+0)/125000}')
      network_upload_mbps=$(awk -v b="$up_bw" 'BEGIN{printf "%d", (b+0)/125000}')
      network_ping_ms=$(echo "$speedtest_output"   | jq -r '.ping.latency // .ping // 0')
      network_jitter_ms=$(echo "$speedtest_output" | jq -r '.ping.jitter // 0')
      network_packet_loss=$(echo "$speedtest_output" | jq -r '.packetLoss // 0')
      echo "$speedtest_output" | jq . || true
    else
      log_warning "Ookla JSON parsing failed"
    fi
  elif [ "$network_method" = "python-cli" ] && command -v speedtest-cli >/dev/null 2>&1; then
    local py_json
    py_json=$(speedtest-cli --json 2>/dev/null || true)
    if [ -n "$py_json" ] && echo "$py_json" | jq . >/dev/null 2>&1; then
      network_download_mbps=$(echo "$py_json" | jq -r '.download' | awk '{printf "%d", $1/1000000}')
      network_upload_mbps=$(echo "$py_json"   | jq -r '.upload'   | awk '{printf "%d", $1/1000000}')
      network_ping_ms=$(echo "$py_json"       | jq -r '.ping // 0')
      echo "$py_json" | jq . || true
    else
      local simple
      simple=$(speedtest-cli --simple 2>/dev/null || true)
      echo "$simple"
      network_download_mbps=$(echo "$simple" | awk '/Download:/ {print int($2+0)}')
      network_upload_mbps=$(echo "$simple"   | awk '/Upload:/   {print int($2+0)}')
      network_ping_ms=$(echo "$simple"       | awk '/Ping:/     {print int($2+0)}')
    fi
  fi

  log_summary "Network Download" "${network_download_mbps} Mbps"
  log_summary "Network Upload"   "${network_upload_mbps} Mbps"
  log_summary "Network Latency"  "${network_ping_ms} ms"
  [ "$network_method" = "ookla" ] && log_summary "Network Jitter"   "${network_jitter_ms} ms"
  [ "$network_method" = "ookla" ] && log_summary "Packet Loss"      "${network_packet_loss}"
  log_success "Network testing completed"
  # Ookla fields: bandwidth(bytes/s), latency/jitter(ms) [web:21][web:18]
}

display_final_summary(){
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

  if [ "$SKIP_NET" = false ] && [ "${network_method:-none}" != "none" ]; then
    printf "\n${CYAN}%-20s %s${NC}\n" "Network Performance" "Mbps"
    printf "%-20s %s\n" "Download:" "$network_download_mbps"
    printf "%-20s %s\n" "Upload:" "$network_upload_mbps"
    printf "%-20s %s ms\n" "Latency:" "$network_ping_ms"
    [ "$network_method" = "ookla" ] && printf "%-20s %s ms\n" "Jitter:" "$network_jitter_ms"
    [ "$network_method" = "ookla" ] && printf "%-20s %s\n" "Packet Loss:" "$network_packet_loss"
    printf "%-20s %s\n" "Method:" "$network_method"
  fi

  printf "\n${GREEN}%-20s${NC}\n" "PERFORMANCE OVERVIEW"
  [ "${cpu_events_single%.*}" -gt 1000 ] && log_success "CPU performance: GOOD (${cpu_events_single} eps)" || log_warning "CPU performance: LOW (${cpu_events_single} eps)"
  [ "${disk_write_buffered_mb_s%.*}" -gt 100 ] && log_success "Disk performance: GOOD (${disk_write_buffered_mb_s} MB/s)" || log_warning "Disk performance: SLOW (${disk_write_buffered_mb_s} MB/s)"
  [ "${network_download_mbps%.*}" -gt 100 ] && log_success "Network performance: GOOD (${network_download_mbps} Mbps)" || log_warning "Network performance: SLOW (${network_download_mbps} Mbps)"

  log_success "Benchmarking completed successfully"
  [ "$OUTPUT_JSON" = true ] && log_info "Detailed results: $SUMMARY_FILE"
  log_info "Temporary files cleaned up"
}

# Main
trap cleanup EXIT INT TERM
parse_arguments "$@"
check_root_privileges "$@"
validate_disk_space
collect_system_info
install_dependencies
log_section "Starting Benchmark Suite"
[ "$SKIP_CPU"  = false ] && run_cpu_benchmarks
[ "$SKIP_DISK" = false ] && run_disk_benchmarks
[ "$SKIP_NET"  = false ] && run_network_benchmarks
display_final_summary
printf "\n${GREEN}Thank you for using VPS Benchmark!${NC}\n"
