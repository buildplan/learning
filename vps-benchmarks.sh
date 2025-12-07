#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C LANG=C

# ============================================================================
# VPS Benchmark Script with Result Comparison v0.2.0
# ============================================================================
# Usage:
#   ./vps-benchmarks.sh              # Run benchmark only
#   ./vps-benchmarks.sh --save       # Run and save to database
#   ./vps-benchmarks.sh --compare    # Run, save, and compare with previous
#   ./vps-benchmarks.sh --list       # List saved benchmark runs
#   ./vps-benchmarks.sh --quick      # Fast benchmark (reduced test times)
#   ./vps-benchmarks.sh --json       # Export results as JSON
# ============================================================================

# --- Constants ---
readonly SCRIPT_VERSION="0.2.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_FILE="${SCRIPT_DIR}/a_testfile"
readonly DB_FILE="${SCRIPT_DIR}/benchmark_results.db"
readonly DEPS_MARKER="${SCRIPT_DIR}/.deps_installed"
readonly LOG_FILE="${SCRIPT_DIR}/benchmark.log"
readonly JSON_FILE="${SCRIPT_DIR}/benchmark_latest.json"
readonly CONFIG_FILE="${SCRIPT_DIR}/.benchmark_config"

# Colors
readonly RED=$'\033[0;31m'
readonly GREEN=$'\033[0;32m'
readonly YELLOW=$'\033[1;33m'
readonly BLUE=$'\033[0;34m'
readonly CYAN=$'\033[0;36m'
readonly NC=$'\033[0m'

# --- Options ---
OPT_SAVE=0
OPT_COMPARE=0
OPT_LIST=0
OPT_QUICK=0
OPT_JSON=0
INSTALL_SPEEDTEST_CLI="ookla"

# --- Configuration (can be overridden by config file) ---
CPU_TEST_TIME=10
DISK_TEST_SIZE=1024  # MB
SKIP_NETWORK=0
NTFY_ENABLED=0
NTFY_URL=""
NTFY_TOKEN=""
NTFY_TOPIC="vps-benchmarks"

# --- Metrics ---
cpu_events_single="N/A"
cpu_events_multi="N/A"
memory_mib_s="N/A"
disk_write_buffered_mb_s="N/A"
disk_write_direct_mb_s="N/A"
disk_read_mb_s="N/A"
disk_latency_us="N/A"
network_download_mbps="N/A"
network_upload_mbps="N/A"
network_ping_ms="N/A"

# ============================================================================
# Helper Functions
# ============================================================================

log_to_file() {
  local level="$1"
  shift
  printf "[%s] [%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >> "$LOG_FILE"
}

error_exit() {
  log_to_file "ERROR" "$1"
  printf "%sError: %s%s\n" "$RED" "$1" "$NC" >&2
  exit 1
}

log_info() {
  printf "\n%s=== %s ===%s\n" "$YELLOW" "$1" "$NC"
  log_to_file "INFO" "$1"
}

log_section() {
  printf "\n%s%s%s\n" "$GREEN" "$1" "$NC"
  log_to_file "SECTION" "$1"
}

log_summary_header() {
  printf "\n%s===================================%s\n" "$GREEN" "$NC"
  printf "%s    %s%s\n" "$GREEN" "$1" "$NC"
  printf "%s===================================%s\n" "$GREEN" "$NC"
}

get_status_indicator() {
  if [ "$1" != "N/A" ]; then
    printf "%s✓%s" "$GREEN" "$NC"
  else
    printf "%s✗%s" "$RED" "$NC"
  fi
}

is_docker() {
  [ -f /.dockerenv ] || grep -q docker /proc/1/cgroup 2>/dev/null
}

cleanup() {
  local exit_code=$?
  [ -f "${TEST_FILE}" ] && rm -f "${TEST_FILE}" || true
  exit ${exit_code}
}

trap cleanup EXIT

# ============================================================================
# Configuration Loading
# ============================================================================

load_config() {
  if [ -f "$CONFIG_FILE" ]; then
    log_to_file "INFO" "Loading configuration from $CONFIG_FILE"
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
  fi
}

# ============================================================================
# Argument Parsing
# ============================================================================

usage() {
  cat <<USAGE
${GREEN}VPS Benchmark Script v${SCRIPT_VERSION}${NC}

${BLUE}Usage:${NC}
  $(basename "$0") [OPTIONS]

${BLUE}Options:${NC}
  -s, --save       Save benchmark results to SQLite database
  -c, --compare    Save and compare with previous benchmark
  -l, --list       List all saved benchmark runs
  -q, --quick      Quick benchmark (reduced test times)
  -j, --json       Export results as JSON
  -h, --help       Show this help message

${BLUE}Examples:${NC}
  $(basename "$0")              # Run benchmark only
  $(basename "$0") --save       # Run and save results
  $(basename "$0") --compare    # Run, save, and compare with last run
  $(basename "$0") --quick      # Fast benchmark (5s CPU, 512MB disk)
  $(basename "$0") --json       # Export as JSON for monitoring

${BLUE}Configuration:${NC}
  Config file: ${CONFIG_FILE}
  Database: ${DB_FILE}
  Log file: ${LOG_FILE}

${BLUE}Environment Variables:${NC}
  NTFY_ENABLED=1               Enable ntfy notifications
  NTFY_URL=https://ntfy.sh     ntfy server URL
  NTFY_TOKEN=tk_xxxxx          ntfy auth token
  NTFY_TOPIC=vps-benchmarks    ntfy topic name
USAGE
  exit 0
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      -s|--save)    OPT_SAVE=1; shift ;;
      -c|--compare) OPT_SAVE=1; OPT_COMPARE=1; shift ;;
      -l|--list)    OPT_LIST=1; shift ;;
      -q|--quick)   OPT_QUICK=1; shift ;;
      -j|--json)    OPT_JSON=1; shift ;;
      -h|--help)    usage ;;
      *) error_exit "Unknown option: $1\nUse --help for usage information" ;;
    esac
  done
}

# ============================================================================
# Database Functions
# ============================================================================

init_database() {
  if [ ! -f "$DB_FILE" ]; then
    log_section "Initializing benchmark database"
    sqlite3 "$DB_FILE" <<SQDBINIT
CREATE TABLE IF NOT EXISTS benchmarks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  timestamp TEXT NOT NULL,
  hostname TEXT NOT NULL,
  version TEXT DEFAULT '1.0.0',
  cpu_single REAL,
  cpu_multi REAL,
  memory_bandwidth REAL,
  disk_write_buffered REAL,
  disk_write_direct REAL,
  disk_read REAL,
  disk_latency REAL,
  network_download REAL,
  network_upload REAL,
  network_ping REAL
);
CREATE INDEX IF NOT EXISTS idx_timestamp ON benchmarks(timestamp);
CREATE INDEX IF NOT EXISTS idx_hostname ON benchmarks(hostname);
CREATE INDEX IF NOT EXISTS idx_version ON benchmarks(version);
SQDBINIT
    printf "%s✓%s Database created: %s\n" "$GREEN" "$NC" "$DB_FILE"
    log_to_file "INFO" "Database initialized"
  fi

  if [ -n "${SUDO_USER:-}" ] && [ -f "$DB_FILE" ]; then
    local user_id group_id
    user_id=$(id -u "$SUDO_USER")
    group_id=$(id -g "$SUDO_USER")
    chown "$user_id:$group_id" "$DB_FILE"
  fi
}

sanitize_sql() {
  echo "${1//\'/\'\'}"
}

save_to_database() {
  local timestamp="$1"
  local hostname
  hostname=$(sanitize_sql "$2")

  # Prepare values (NULL if N/A)
  local cpu_s cpu_m mem_bw disk_wb disk_wd disk_r disk_lat net_d net_u net_p
  cpu_s="${cpu_events_single//N\/A/NULL}"
  cpu_m="${cpu_events_multi//N\/A/NULL}"
  mem_bw="${memory_mib_s//N\/A/NULL}"
  disk_wb="${disk_write_buffered_mb_s//N\/A/NULL}"
  disk_wd="${disk_write_direct_mb_s//N\/A/NULL}"
  disk_r="${disk_read_mb_s//N\/A/NULL}"
  disk_lat="${disk_latency_us//N\/A/NULL}"
  net_d="${network_download_mbps//N\/A/NULL}"
  net_u="${network_upload_mbps//N\/A/NULL}"
  net_p="${network_ping_ms//N\/A/NULL}"

  local new_id
  new_id=$(sqlite3 "$DB_FILE" <<DBENTRY
INSERT INTO benchmarks (
  timestamp, hostname, version, cpu_single, cpu_multi, memory_bandwidth,
  disk_write_buffered, disk_write_direct, disk_read, disk_latency,
  network_download, network_upload, network_ping
) VALUES (
  '$timestamp', '$hostname', '$SCRIPT_VERSION', $cpu_s, $cpu_m, $mem_bw,
  $disk_wb, $disk_wd, $disk_r, $disk_lat, $net_d, $net_u, $net_p
);
SELECT last_insert_rowid();
DBENTRY
)
  printf "\n%s✓%s Results saved to database (ID: %s)\n" "$GREEN" "$NC" "$new_id"
  log_to_file "INFO" "Saved to database with ID: $new_id"
}

list_benchmarks() {
  if [ ! -f "$DB_FILE" ]; then
    printf "%sNo benchmark database found%s\n" "$YELLOW" "$NC"
    exit 0
  fi
  log_info "Saved Benchmark Runs"
  sqlite3 -header -column "$DB_FILE" <<LISTBM
SELECT
  id,
  datetime(timestamp) as run_time,
  hostname,
  version,
  printf("%.1f", COALESCE(cpu_single, 0)) as cpu_s,
  printf("%.1f", COALESCE(cpu_multi, 0)) as cpu_m,
  printf("%d", COALESCE(disk_write_buffered, 0)) as disk_w,
  printf("%d", COALESCE(network_download, 0)) as net_dl
FROM benchmarks ORDER BY timestamp DESC LIMIT 20;
LISTBM
  exit 0
}

compare_with_previous() {
  local current_hostname
  current_hostname=$(sanitize_sql "$1")
  local prev_data
  prev_data=$(sqlite3 "$DB_FILE" <<LISTP
SELECT
  cpu_single, cpu_multi, memory_bandwidth, disk_write_buffered, disk_write_direct,
  disk_read, disk_latency, network_download, network_upload, network_ping,
  datetime(timestamp), version
FROM benchmarks WHERE hostname = '$current_hostname'
ORDER BY timestamp DESC LIMIT 1 OFFSET 1;
LISTP
)

  if [ -z "$prev_data" ]; then
    printf "\n%sNo previous benchmark found for comparison%s\n" "$YELLOW" "$NC"
    return
  fi

  local prev_cpu_s prev_cpu_m prev_mem prev_disk_wb prev_disk_wd prev_disk_r \
        prev_disk_lat prev_net_d prev_net_u prev_net_p prev_timestamp prev_version

  IFS='|' read -r prev_cpu_s prev_cpu_m prev_mem prev_disk_wb prev_disk_wd prev_disk_r \
                  prev_disk_lat prev_net_d prev_net_u prev_net_p prev_timestamp prev_version <<< "$prev_data"

  log_summary_header "COMPARISON WITH PREVIOUS RUN"
  printf "%sPrevious Run:%s %s (v%s)\n" "$BLUE" "$NC" "$prev_timestamp" "${prev_version:-1.0.0}"

compare_metric() {
  local name="$1"
  local current="$2"
  local previous="$3"
  local higher_is_better="${4:-1}"

  if [ "$current" = "N/A" ] || [ -z "$previous" ] || [ "$previous" = "NULL" ]; then
    if [ "$current" = "N/A" ]; then
      printf "  %-25s: %s\n" "$name" "N/A"
    else
      printf "  %-25s: %s → %s %s(new)%s\n" "$name" "N/A" "$current" "$BLUE" "$NC"
    fi
    return
  fi

  local diff abs_diff
  diff=$(echo "scale=2; (($current - $previous) / $previous) * 100" | bc)
  abs_diff=$(echo "$diff" | tr -d '-')

  local is_improvement=0
  if (( $(echo "$diff > 0" | bc -l) )); then
    [ "$higher_is_better" -eq 1 ] && is_improvement=1
  else
    [ "$higher_is_better" -eq 0 ] && is_improvement=1
  fi

  local color=$RED
  local symbol="▼"
  if [ "$is_improvement" -eq 1 ]; then
    color=$GREEN
    symbol="▲"
  elif (( $(echo "$abs_diff < 2" | bc -l) )); then
    color=$NC
    symbol="≈"
  fi

  printf "  %-25s: %s → %s %s(%s%.1f%%)%s\n" \
         "$name" "$previous" "$current" "$color" "$symbol" "$abs_diff" "$NC"
}

  printf "\n%sCPU Performance:%s\n" "$CYAN" "$NC"
  compare_metric "Single-Thread (ev/s)" "$cpu_events_single" "$prev_cpu_s" 1
  compare_metric "Multi-Thread (ev/s)" "$cpu_events_multi" "$prev_cpu_m" 1

  printf "\n%sMemory Performance:%s\n" "$CYAN" "$NC"
  compare_metric "Bandwidth (MiB/s)" "$memory_mib_s" "$prev_mem" 1

  printf "\n%sDisk Performance (MB/s):%s\n" "$CYAN" "$NC"
  compare_metric "Write Buffered" "$disk_write_buffered_mb_s" "$prev_disk_wb" 1
  compare_metric "Write Direct" "$disk_write_direct_mb_s" "$prev_disk_wd" 1
  compare_metric "Read Direct" "$disk_read_mb_s" "$prev_disk_r" 1
  compare_metric "Latency (μs)" "$disk_latency_us" "$prev_disk_lat" 0

  printf "\n%sNetwork Performance:%s\n" "$CYAN" "$NC"
  compare_metric "Download (Mbps)" "$network_download_mbps" "$prev_net_d" 1
  compare_metric "Upload (Mbps)" "$network_upload_mbps" "$prev_net_u" 1
  compare_metric "Latency (ms)" "$network_ping_ms" "$prev_net_p" 0
}

# ============================================================================
# JSON Export
# ============================================================================

export_json() {
  cat > "$JSON_FILE" <<JSON
{
  "version": "$SCRIPT_VERSION",
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "hostname": "$(hostname)",
  "is_docker": $(is_docker && echo "true" || echo "false"),
  "metrics": {
    "cpu": {
      "single_thread_events_per_sec": ${cpu_events_single//N\/A/null},
      "multi_thread_events_per_sec": ${cpu_events_multi//N\/A/null}
    },
    "memory": {
      "bandwidth_mib_per_sec": ${memory_mib_s//N\/A/null}
    },
    "disk": {
      "write_buffered_mbs": ${disk_write_buffered_mb_s//N\/A/null},
      "write_direct_mbs": ${disk_write_direct_mb_s//N\/A/null},
      "read_mbs": ${disk_read_mb_s//N\/A/null},
      "latency_us": ${disk_latency_us//N\/A/null}
    },
    "network": {
      "download_mbps": ${network_download_mbps//N\/A/null},
      "upload_mbps": ${network_upload_mbps//N\/A/null},
      "latency_ms": ${network_ping_ms//N\/A/null}
    }
  }
}
JSON
  printf "%s✓%s JSON exported to: %s\n" "$GREEN" "$NC" "$JSON_FILE"
  log_to_file "INFO" "JSON exported to $JSON_FILE"

  # Set ownership if run as sudo
  if [ -n "${SUDO_USER:-}" ]; then
    chown "$(id -u "$SUDO_USER"):$(id -g "$SUDO_USER")" "$JSON_FILE"
  fi
}

# ============================================================================
# ntfy Notification
# ============================================================================

send_ntfy_notification() {
  [ "$NTFY_ENABLED" -ne 1 ] && return 0
  [ -z "$NTFY_URL" ] && return 0

  local title="$1"
  local message="$2"
  local priority="${3:-default}"

  local auth_header=""
  [ -n "$NTFY_TOKEN" ] && auth_header="-H \"Authorization: Bearer $NTFY_TOKEN\""

  log_to_file "INFO" "Sending ntfy notification: $title"

  eval curl -sf -X POST "\"$NTFY_URL/$NTFY_TOPIC\"" \
    $auth_header \
    -H \"Title: $title\" \
    -H \"Priority: $priority\" \
    -d \"$message\" &>/dev/null || {
    log_to_file "WARN" "Failed to send ntfy notification"
  }
}

# ============================================================================
# System Health Checks
# ============================================================================

check_system_health() {
  log_section "System Health Checks"

  # Check disk space
  local disk_usage
  disk_usage=$(df -h "$SCRIPT_DIR" | awk 'NR==2 {print $5}' | tr -d '%')
  if [ "$disk_usage" -gt 90 ]; then
    printf "%sWarning: Disk usage at %s%%%s\n" "$YELLOW" "$disk_usage" "$NC"
    log_to_file "WARN" "High disk usage: ${disk_usage}%"
  else
    printf "%s✓%s Disk usage: %s%%\n" "$GREEN" "$NC" "$disk_usage"
  fi

  # Check load average
  local load_avg cpu_count load_per_cpu
  load_avg=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | tr -d ',')
  cpu_count=$(nproc)
  load_per_cpu=$(echo "scale=2; $load_avg / $cpu_count" | bc)
  printf "Current load: %s (%.2f per CPU)\n" "$load_avg" "$load_per_cpu"

  # Check if in Docker
  if is_docker; then
    printf "%sℹ%s Running in Docker container (some tests may be affected)\n" "$BLUE" "$NC"
    log_to_file "INFO" "Running in Docker container"
  fi
}

# ============================================================================
# Installation & Dependency Management
# ============================================================================

verify_all_dependencies() {
  for tool in sysbench bc sqlite3 curl ioping; do
    command -v "$tool" &>/dev/null || return 1
  done
  command -v speedtest &>/dev/null || command -v speedtest-cli &>/dev/null || return 1
  return 0
}

check_and_install_dependencies() {
  # Check marker file first (fastest path)
  if [ -f "$DEPS_MARKER" ]; then
    if verify_all_dependencies; then
      log_info "Dependencies"
      printf "%s✓%s All dependencies verified (cached). Skipping checks.\n" "$GREEN" "$NC"
      return 0
    else
      rm -f "$DEPS_MARKER"  # Marker invalid, recheck
      log_to_file "WARN" "Dependency marker invalid, rechecking"
    fi
  fi

  local missing_deps=0

  # Check core tools
  for tool in sysbench bc sqlite3 curl ioping; do
    if ! command -v "$tool" &>/dev/null; then
      missing_deps=1
      break
    fi
  done

  if [ $missing_deps -eq 0 ]; then
    if ! command -v speedtest &>/dev/null && ! command -v speedtest-cli &>/dev/null; then
      missing_deps=1
    fi
  fi

  # If everything exists, create marker and return
  if [ $missing_deps -eq 0 ]; then
    log_info "Dependencies"
    printf "%s✓%s All dependencies already installed.\n" "$GREEN" "$NC"
    touch "$DEPS_MARKER"
    [ -n "${SUDO_USER:-}" ] && chown "$(id -u "$SUDO_USER"):$(id -g "$SUDO_USER")" "$DEPS_MARKER"
    log_to_file "INFO" "All dependencies verified, marker created"
    return 0
  fi

  # --- Installation Required ---
  if [ "$(id -u)" -ne 0 ]; then
    error_exit "Missing dependencies. This script must run as root to install them."
  fi

  log_info "Dependencies"
  log_section "Installing missing dependencies (sysbench + speedtest + bc + sqlite3)"
  log_to_file "INFO" "Installing dependencies"

  if command -v apt-get &>/dev/null; then install_debian_based
  elif command -v dnf &>/dev/null; then install_fedora_based
  elif command -v yum &>/dev/null; then install_redhat_based
  else error_exit "Unsupported package manager"; fi

  # Create marker after successful install
  touch "$DEPS_MARKER"
  [ -n "${SUDO_USER:-}" ] && chown "$(id -u "$SUDO_USER"):$(id -g "$SUDO_USER")" "$DEPS_MARKER"
  log_to_file "INFO" "Dependencies installed successfully"
}

try_install_speedtest_ookla() {
  local script_url="$1"
  local pkg_manager="$2"

  if command -v speedtest >/dev/null; then
    return 0
  fi

  if curl -sfS "$script_url" | bash; then
    if "$pkg_manager" install -y speedtest 2>/dev/null; then
      printf "%s✓%s Ookla Speedtest installed\n" "$GREEN" "$NC"
      return 0
    fi
  fi
  return 1
}

install_debian_based() {
  apt-get update -y || error_exit "Failed to update apt cache"
  apt-get install -y sysbench curl ca-certificates bc sqlite3 ioping 2>/dev/null || \
    apt-get install -y sysbench curl ca-certificates bc sqlite3 || \
    error_exit "Failed to install base packages"

  if ! command -v speedtest &>/dev/null; then
    if try_install_speedtest_ookla "https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh" "apt-get"; then
      return 0
    fi
    install_speedtest_python
  fi
}

install_fedora_based() {
  dnf install -y sysbench curl ca-certificates bc sqlite ioping 2>/dev/null || \
    dnf install -y sysbench curl ca-certificates bc sqlite || true

  if ! command -v sysbench &>/dev/null; then
    dnf install -y epel-release && dnf install -y sysbench
  fi

  if ! command -v speedtest &>/dev/null; then
    if try_install_speedtest_ookla "https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh" "dnf"; then
      return 0
    fi
    install_speedtest_python
  fi
}

install_redhat_based() {
  yum install -y epel-release || true
  yum install -y sysbench curl ca-certificates bc sqlite ioping 2>/dev/null || \
    yum install -y sysbench curl ca-certificates bc sqlite || \
    error_exit "Failed to install base packages"

  if ! command -v speedtest &>/dev/null; then
    if try_install_speedtest_ookla "https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh" "yum"; then
      return 0
    fi
    install_speedtest_python
  fi
}

install_speedtest_python() {
  if command -v speedtest-cli >/dev/null; then
    INSTALL_SPEEDTEST_CLI="python"
    return 0
  fi

  if command -v pip3 &>/dev/null || apt-get install -y python3-pip || dnf install -y python3-pip || yum install -y python3-pip; then
    pip3 install --break-system-packages speedtest-cli 2>/dev/null || {
      printf "%sWarning: Failed to install speedtest-cli via pip%s\n" "$YELLOW" "$NC"
      INSTALL_SPEEDTEST_CLI="none"
    }
    if command -v speedtest-cli &>/dev/null; then
      INSTALL_SPEEDTEST_CLI="python"
      printf "%s✓%s speedtest-cli (Python) installed\n" "$GREEN" "$NC"
    fi
  else
    printf "%sWarning: Could not install pip or speedtest-cli%s\n" "$YELLOW" "$NC"
    INSTALL_SPEEDTEST_CLI="none"
  fi
}

# ============================================================================
# Benchmark Functions
# ============================================================================

parse_dd() {
  local dd_output="$1"
  local speed
  speed=$(echo "$dd_output" | grep -Eo '[0-9]+(\.[0-9]+)? [GM]B/s' | tail -n 1)
  if [ -z "$speed" ]; then printf "0"; return 1; fi
  if echo "$speed" | grep -q "GB/s"; then
    echo "$speed" | awk '{print $1 * 1024}' | cut -d'.' -f1
  else
    echo "$speed" | awk '{print $1}' | cut -d'.' -f1
  fi
}

run_cpu_benchmarks() {
  local cpu_out_single
  log_section "CPU Benchmark: Single Thread (${CPU_TEST_TIME}s, max-prime=20000)"
  cpu_out_single=$(sysbench cpu --time="${CPU_TEST_TIME}" --threads=1 --cpu-max-prime=20000 run)
  echo "$cpu_out_single" | grep 'events per second:' | sed 's/^[ \t]*//'
  cpu_events_single=$(echo "$cpu_out_single" | awk -F': ' '/events per second:/ {print $2; exit}')

  local cpu_count cpu_out_multi
  cpu_count=$(nproc)
  log_section "CPU Benchmark: Multi Thread (${cpu_count} threads, ${CPU_TEST_TIME}s)"
  cpu_out_multi=$(sysbench cpu --time="${CPU_TEST_TIME}" --threads="${cpu_count}" --cpu-max-prime=20000 run)
  echo "$cpu_out_multi" | grep 'events per second:' | sed 's/^[ \t]*//'
  cpu_events_multi=$(echo "$cpu_out_multi" | awk -F': ' '/events per second:/ {print $2; exit}')

  log_to_file "INFO" "CPU Single: $cpu_events_single ev/s, Multi: $cpu_events_multi ev/s"
}

run_memory_benchmark() {
  log_section "Memory Benchmark (${CPU_TEST_TIME}s, 1GB blocks)"
  local mem_out
  mem_out=$(sysbench memory --memory-block-size=1M --memory-total-size=10G --time="${CPU_TEST_TIME}" run)
  echo "$mem_out" | grep 'transferred'
  memory_mib_s=$(echo "$mem_out" | awk '/transferred/ {gsub(/[()]/, "", $4); print $4; exit}')
  [ -z "$memory_mib_s" ] && memory_mib_s="N/A"
  log_to_file "INFO" "Memory bandwidth: $memory_mib_s MiB/s"
}

run_disk_benchmarks() {
  local dd_out_buffered
  log_section "Disk Write (${DISK_TEST_SIZE}MiB, buffered+flush)"
  dd_out_buffered=$(dd if=/dev/zero of="${TEST_FILE}" bs=1M count="${DISK_TEST_SIZE}" conv=fdatasync status=progress 2>&1 | tail -n 1)
  echo "$dd_out_buffered"
  disk_write_buffered_mb_s=$(parse_dd "$dd_out_buffered")

  local dd_out_direct
  log_section "Disk Write (${DISK_TEST_SIZE}MiB, direct I/O)"
  dd_out_direct=$(dd if=/dev/zero of="${TEST_FILE}" bs=1M count="${DISK_TEST_SIZE}" oflag=direct status=progress 2>&1 | tail -n 1)
  echo "$dd_out_direct"
  disk_write_direct_mb_s=$(parse_dd "$dd_out_direct")

  local dd_out_read
  log_section "Disk Read (${DISK_TEST_SIZE}MiB, direct I/O)"
  dd_out_read=$(dd if="${TEST_FILE}" of=/dev/null bs=1M count="${DISK_TEST_SIZE}" iflag=direct status=progress 2>&1 | tail -n 1)
  echo "$dd_out_read"
  disk_read_mb_s=$(parse_dd "$dd_out_read")

  log_to_file "INFO" "Disk - Write Buf: $disk_write_buffered_mb_s MB/s, Write Direct: $disk_write_direct_mb_s MB/s, Read: $disk_read_mb_s MB/s"
}

run_disk_latency_benchmark() {
  if ! command -v ioping &>/dev/null; then
    log_to_file "INFO" "ioping not available, skipping latency test"
    return
  fi

  log_section "Disk Latency (ioping, 20 requests)"
  local ioping_out
  ioping_out=$(ioping -c 20 "${SCRIPT_DIR}" 2>&1)
  echo "$ioping_out"

  local latency_value latency_unit
  latency_value=$(echo "$ioping_out" | awk '/min\/avg\/max/ {print $6; exit}')
  latency_unit=$(echo "$ioping_out" | awk '/min\/avg\/max/ {print $7; exit}')

  if [ "$latency_unit" = "ms" ]; then
    disk_latency_us=$(echo "$latency_value * 1000" | bc | cut -d'.' -f1)
  else
    disk_latency_us=$(echo "$latency_value" | cut -d'.' -f1)
  fi

  [ -z "$disk_latency_us" ] && disk_latency_us="N/A"
  log_to_file "INFO" "Disk latency: $disk_latency_us μs"
}

run_network_benchmark() {
  if [ "$SKIP_NETWORK" -eq 1 ]; then
    log_section "Network Speed Test (skipped by config)"
    return 0
  fi

  log_section "Network Speed Test (${INSTALL_SPEEDTEST_CLI})"
  local out
  local exit_code=0

  if command -v speedtest &>/dev/null; then
    out=$(timeout 300 speedtest --accept-license --accept-gdpr 2>&1) || exit_code=$?
    printf "%s\n" "$out"

    if [ $exit_code -ne 0 ]; then
      printf "%sWarning: Ookla speedtest exited with code %s (upload may have failed)%s\n" \
             "$YELLOW" "$exit_code" "$NC"
      log_to_file "WARN" "Ookla speedtest exited with code $exit_code"
    fi

    extract_first_number() {
      local pattern="$1"
      echo "$out" | awk -v pat="$pattern" \
        '$0 ~ pat { for(i=1;i<=NF;i++) if($i ~ /^[0-9]+(\.[0-9]+)?$/) {print $i; exit} }' \
        | head -n1
    }

    network_download_mbps=$(extract_first_number "^[[:space:]]*Download:")
    network_upload_mbps=$(extract_first_number "^[[:space:]]*Upload:")
    network_ping_ms=$(extract_first_number "Idle Latency:")
    [ -z "$network_ping_ms" ] && network_ping_ms=$(extract_first_number "^[[:space:]]*Latency:")

  elif command -v speedtest-cli &>/dev/null; then
    out=$(timeout 300 speedtest-cli --simple 2>&1) || exit_code=$?
    printf "%s\n" "$out"

    if [ $exit_code -ne 0 ]; then
      printf "%sWarning: speedtest-cli exited with code %s (partial results may still be valid)%s\n" \
             "$YELLOW" "$exit_code" "$NC"
      log_to_file "WARN" "speedtest-cli exited with code $exit_code"
    fi

    extract_simple() {
      local pattern="$1"
      echo "$out" | awk -v pat="$pattern" \
        '$0 ~ pat { for(i=1;i<=NF;i++) if($i ~ /^[0-9]+(\.[0-9]+)?$/) {print $i; exit} }' \
        | head -n1
    }

    network_download_mbps=$(extract_simple "^Download:")
    network_upload_mbps=$(extract_simple "^Upload:")
    network_ping_ms=$(extract_simple "^Ping:")
  else
    printf "%sNo speedtest tool available%s\n" "$RED" "$NC"
    log_to_file "ERROR" "No speedtest tool available"
    return 1
  fi

  [ -z "$network_download_mbps" ] && network_download_mbps="N/A"
  [ -z "$network_upload_mbps" ] && network_upload_mbps="N/A"
  [ -z "$network_ping_ms" ] && network_ping_ms="N/A"

  printf "%s✓%s Network speed test complete (Down: %s Mbps, Up: %s Mbps, Ping: %s ms)\n" \
         "$GREEN" "$NC" "$network_download_mbps" "$network_upload_mbps" "$network_ping_ms"
  log_to_file "INFO" "Network - Down: $network_download_mbps Mbps, Up: $network_upload_mbps Mbps, Ping: $network_ping_ms ms"

  return 0
}

display_system_info() {
  log_info "System Info"
  printf "Script Version: %s\n" "$SCRIPT_VERSION"
  printf "Hostname: %s\n" "$(hostname)"
  printf "Uptime: %s\n" "$(uptime -p)"
  printf "CPU Info:\n"
  lscpu | grep -E '^Model name:|^CPU\(s\):|^Thread\(s\) per core:|^Core\(s\) per socket:' | sed 's/^[ \t]*//'
  printf "\nMemory:\n"
  free -h
  printf "\nDisk:\n"
  lsblk -o NAME,SIZE,TYPE,MOUNTPOINT
}

display_results() {
  local timestamp="$1"
  log_summary_header "FINAL RESULTS SUMMARY"
  printf "\n%sExecution Details:%s\n" "$BLUE" "$NC"
  printf "  %-20s: %s\n" "Version" "$SCRIPT_VERSION"
  printf "  %-20s: %s\n" "Hostname" "$(hostname)"
  printf "  %-20s: %s\n" "Timestamp" "$timestamp"
  printf "  %-20s: %s%s%s\n" "Status" "$GREEN" "Completed" "$NC"

  local i_cpu_s i_cpu_m i_mem
  i_cpu_s=$(get_status_indicator "$cpu_events_single")
  i_cpu_m=$(get_status_indicator "$cpu_events_multi")
  i_mem=$(get_status_indicator "$memory_mib_s")

  printf "\n%sCPU Performance (sysbench):%s\n" "$CYAN" "$NC"
  printf "  %-20s [%s]: %s%s%s events/sec\n" "Single-Thread" "$i_cpu_s" "$GREEN" "$cpu_events_single" "$NC"
  printf "  %-20s [%s]: %s%s%s events/sec\n" "Multi-Thread" "$i_cpu_m" "$GREEN" "$cpu_events_multi" "$NC"

  printf "\n%sMemory Performance:%s\n" "$CYAN" "$NC"
  printf "  %-20s [%s]: %s%s%s MiB/s\n" "Bandwidth" "$i_mem" "$GREEN" "$memory_mib_s" "$NC"

  local i_d_wb i_d_wd i_d_r i_d_lat
  i_d_wb=$(get_status_indicator "$disk_write_buffered_mb_s")
  i_d_wd=$(get_status_indicator "$disk_write_direct_mb_s")
  i_d_r=$(get_status_indicator "$disk_read_mb_s")
  i_d_lat=$(get_status_indicator "$disk_latency_us")

  printf "\n%sDisk Performance:%s\n" "$CYAN" "$NC"
  printf "  %-20s [%s]: %s%s%s MB/s\n" "Write (Buffered)" "$i_d_wb" "$GREEN" "$disk_write_buffered_mb_s" "$NC"
  printf "  %-20s [%s]: %s%s%s MB/s\n" "Write (Direct)" "$i_d_wd" "$GREEN" "$disk_write_direct_mb_s" "$NC"
  printf "  %-20s [%s]: %s%s%s MB/s\n" "Read (Direct)" "$i_d_r" "$GREEN" "$disk_read_mb_s" "$NC"
  printf "  %-20s [%s]: %s%s%s μs\n" "Latency" "$i_d_lat" "$GREEN" "$disk_latency_us" "$NC"

  local i_n_d i_n_u i_n_p
  i_n_d=$(get_status_indicator "$network_download_mbps")
  i_n_u=$(get_status_indicator "$network_upload_mbps")
  i_n_p=$(get_status_indicator "$network_ping_ms")

  printf "\n%sNetwork Performance (speedtest):%s\n" "$CYAN" "$NC"
  printf "  %-20s [%s]: %s%s%s Mbps\n" "Download" "$i_n_d" "$GREEN" "$network_download_mbps" "$NC"
  printf "  %-20s [%s]: %s%s%s Mbps\n" "Upload" "$i_n_u" "$GREEN" "$network_upload_mbps" "$NC"
  printf "  %-20s [%s]: %s%s%s ms\n" "Latency" "$i_n_p" "$GREEN" "$network_ping_ms" "$NC"
}

# ============================================================================
# Main
# ============================================================================

main() {
  parse_args "$@"

  # Handle list command
  [ "$OPT_LIST" -eq 1 ] && list_benchmarks

  # Load configuration
  load_config

  # Apply quick mode adjustments
  if [ "$OPT_QUICK" -eq 1 ]; then
    CPU_TEST_TIME=5
    DISK_TEST_SIZE=512
    log_to_file "INFO" "Quick mode enabled"
  fi

  printf "%s============================================%s\n" "$GREEN" "$NC"
  printf "%s  VPS Benchmark Script v%s%s\n" "$GREEN" "$SCRIPT_VERSION" "$NC"
  printf "%s============================================%s\n" "$GREEN" "$NC"

  display_system_info
  check_system_health
  check_and_install_dependencies

  log_info "Starting Benchmarks"
  log_to_file "INFO" "=== Benchmark Started ==="

  run_cpu_benchmarks
  run_memory_benchmark
  run_disk_benchmarks
  run_disk_latency_benchmark
  run_network_benchmark || printf "%sWarning: Network test failed%s\n" "$YELLOW" "$NC"

  BENCHMARK_END=$(date '+%Y-%m-%d %H:%M:%S')
  display_results "$BENCHMARK_END"

  # Save results
  if [ "$OPT_SAVE" -eq 1 ] || [ "$OPT_COMPARE" -eq 1 ]; then
    init_database
    save_to_database "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(hostname)"
  fi

  # Compare with previous
  if [ "$OPT_COMPARE" -eq 1 ]; then
    compare_with_previous "$(hostname)"
  fi

  # Export JSON
  if [ "$OPT_JSON" -eq 1 ] || [ "$OPT_SAVE" -eq 1 ]; then
    export_json
  fi

  # Send notification
  if [ "$NTFY_ENABLED" -eq 1 ]; then
    local summary="$(hostname): CPU ${cpu_events_multi}ev/s | Disk ${disk_write_buffered_mb_s}MB/s | Net ${network_download_mbps:-N/A}↓/${network_upload_mbps:-N/A}↑ Mbps"
    send_ntfy_notification "VPS Benchmark Complete" "$summary" "default"
  fi

  log_to_file "INFO" "=== Benchmark Completed Successfully ==="
  printf "\n%sSystem benchmarking completed successfully.%s\n" "$GREEN" "$NC"
  printf "\n%sFiles created:%s\n" "$BLUE" "$NC"
  [ "$OPT_SAVE" -eq 1 ] && printf "  • Database: %s\n" "$DB_FILE"
  [ "$OPT_JSON" -eq 1 ] || [ "$OPT_SAVE" -eq 1 ] && printf "  • JSON: %s\n" "$JSON_FILE"
  printf "  • Log: %s\n" "$LOG_FILE"
}

main "$@"
