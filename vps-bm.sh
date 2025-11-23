#!/bin/sh
set -eu
export LC_ALL=C
export LANG=C

# ============================================================================
# VPS Benchmark Script (POSIX sh Compliant)
# ============================================================================

# Disk directory selection:
DISK_DIR_DEFAULT=${PWD:-.}
DISK_DIR=${BENCH_TMPDIR:-$DISK_DIR_DEFAULT}

# TEST_FILE will be set in main() after parsing options
TEST_FILE=""

DB_FILE="${PWD:-.}/benchmark_results.db"

# Colors (portable)
RED=$(printf '\033[0;31m')
GREEN=$(printf '\033[0;32m')
YELLOW=$(printf '\033[1;33m')
BLUE=$(printf '\033[0;34m')
CYAN=$(printf '\033[0;36m')
NC=$(printf '\033[0m')

# Global Metrics
cpu_events_single="N/A"
cpu_events_multi="N/A"
disk_write_buffered_mb_s="N/A"
disk_write_direct_mb_s="N/A"
disk_read_mb_s="N/A"
network_download_mbps="N/A"
network_upload_mbps="N/A"
network_ping_ms="N/A"

# Options
OPT_SAVE=0
OPT_COMPARE=0
OPT_LIST=0
INSTALL_SPEEDTEST_CLI="ookla"

# ============================================================================
# Helpers
# ============================================================================

cleanup() {
  exit_code=$?
  if [ -n "${TEST_FILE:-}" ] && [ -f "$TEST_FILE" ]; then
    rm -f "$TEST_FILE" >/dev/null 2>&1 || true
  fi
  exit "$exit_code"
}
trap 'cleanup' 0 HUP INT TERM

error_exit() {
  printf "%sError: %s%s\n" "$RED" "$1" "$NC" >&2
  exit 1
}

log_info() { printf "\n%s=== %s ===%s\n" "$YELLOW" "$1" "$NC"; }
log_section() { printf "\n%s%s%s\n" "$GREEN" "$1" "$NC"; }

log_summary_header() {
  printf "\n%s===================================%s\n" "$GREEN" "$NC"
  printf "%s    %s%s\n" "$GREEN" "$1" "$NC"
  printf "%s===================================%s\n" "$GREEN" "$NC"
}

get_status_indicator() {
  if [ "$1" != "N/A" ]; then printf "%s✓%s" "$GREEN" "$NC"; else printf "%s✗%s" "$RED" "$NC"; fi
}

to_sql_null() {
  if [ "$1" = "N/A" ]; then printf "NULL"; else printf "%s" "$1"; fi
}

sanitize_sql() {
  printf "%s" "$1" | sed "s/'/''/g"
}

yes_no_prompt() {
  while :; do
    printf "%s (y/n): " "$1"
    read ans || exit 1
    case $ans in
      [Yy]*) return 0 ;;
      [Nn]*) return 1 ;;
      *) printf "Please answer y or n.\n" ;;
    esac
  done
}

run_with_timeout() {
  _duration=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$_duration" "$@"
  else
    "$@"
  fi
}

# ============================================================================
# Database
# ============================================================================

init_database() {
  if [ ! -f "$DB_FILE" ]; then
    log_section "Initializing benchmark database"
    if ! command -v sqlite3 >/dev/null 2>&1; then
      printf "%sWarning: sqlite3 not found. Results will not be saved.%s\n" "$YELLOW" "$NC"
      OPT_SAVE=0
      return
    fi

    sqlite3 "$DB_FILE" <<SQDBINIT
CREATE TABLE IF NOT EXISTS benchmarks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  timestamp TEXT NOT NULL,
  hostname TEXT NOT NULL,
  bench_dir TEXT,
  cpu_single REAL,
  cpu_multi REAL,
  disk_write_buffered REAL,
  disk_write_direct REAL,
  disk_read REAL,
  network_download REAL,
  network_upload REAL,
  network_ping REAL
);
CREATE INDEX IF NOT EXISTS idx_timestamp ON benchmarks(timestamp);
CREATE INDEX IF NOT EXISTS idx_hostname ON benchmarks(hostname);
SQDBINIT

    if [ -n "${SUDO_USER:-}" ]; then
      chown "$(id -u "$SUDO_USER")":"$(id -g "$SUDO_USER")" "$DB_FILE" || true
    fi
  fi
}

save_to_database() {
  [ "$OPT_SAVE" -eq 0 ] && return
  _ts=$1
  _host=$(sanitize_sql "$2")
  _dir=$(sanitize_sql "$DISK_DIR")

  _sql="INSERT INTO benchmarks (
    timestamp, hostname, bench_dir, cpu_single, cpu_multi,
    disk_write_buffered, disk_write_direct, disk_read,
    network_download, network_upload, network_ping
  ) VALUES (
    '$_ts', '$_host', '$_dir',
    $(to_sql_null "$cpu_events_single"), $(to_sql_null "$cpu_events_multi"),
    $(to_sql_null "$disk_write_buffered_mb_s"), $(to_sql_null "$disk_write_direct_mb_s"),
    $(to_sql_null "$disk_read_mb_s"), $(to_sql_null "$network_download_mbps"),
    $(to_sql_null "$network_upload_mbps"), $(to_sql_null "$network_ping_ms")
  ); SELECT last_insert_rowid();"

  _new_id=$(printf "%s" "$_sql" | sqlite3 "$DB_FILE")
  printf "\n%s✓%s Results saved to database (ID: %s)\n" "$GREEN" "$NC" "$_new_id"
}

list_benchmarks() {
  if [ ! -f "$DB_FILE" ]; then printf "%sNo benchmark database found%s\n" "$YELLOW" "$NC"; exit 0; fi
  log_info "Saved Benchmark Runs"
  sqlite3 -header -column "$DB_FILE" "SELECT id, datetime(timestamp) as run_time, hostname, bench_dir, printf('%.1f', COALESCE(cpu_single, 0)) as cpu_s, printf('%d', COALESCE(disk_write_buffered, 0)) as disk_w FROM benchmarks ORDER BY timestamp DESC LIMIT 20;"
  exit 0
}

compare_with_previous() {
  [ ! -f "$DB_FILE" ] && return
  _host=$(sanitize_sql "$1")
  _prev_data=$(sqlite3 "$DB_FILE" "SELECT cpu_single, cpu_multi, disk_write_buffered, disk_write_direct, disk_read, network_download, network_upload, network_ping, datetime(timestamp) FROM benchmarks WHERE hostname = '$_host' ORDER BY timestamp DESC LIMIT 1 OFFSET 1;")

  if [ -z "$_prev_data" ]; then
    printf "%sNo previous benchmark found for comparison%s\n" "$YELLOW" "$NC"
    return
  fi

  IFS='|' read -r _pcs _pcm _dwb _dwd _dr _nd _nu _np _pts <<EOF
$_prev_data
EOF

  _compare() {
    _n=$1; _c=$2; _p=$3; _hib=${4:-1}
    if [ "$_c" = "N/A" ] || [ -z "$_p" ] || [ "$_p" = "NULL" ]; then printf "  %-20s: %s\n" "$_n" "$_c"; return; fi
    _diff=$(printf 'scale=2; (%s - %s) / %s * 100\n' "$_c" "$_p" "$_p" | bc 2>/dev/null || echo 0)
    _abs=$(printf '%s' "$_diff" | tr -d '-')
    _pos=$(printf '%s > 0\n' "$_diff" | bc 2>/dev/null || echo 0)

    _good=0
    if [ "$_pos" -eq 1 ] && [ "$_hib" -eq 1 ]; then _good=1; fi
    if [ "$_pos" -eq 0 ] && [ "$_hib" -eq 0 ]; then _good=1; fi

    _col=$RED; _sym="▼"
    [ "$_good" -eq 1 ] && _col=$GREEN && _sym="▲"
    [ "$(printf '%s < 2\n' "$_abs" | bc 2>/dev/null)" -eq 1 ] && _col=$NC && _sym="≈"
    printf "  %-20s: %s -> %s %s(%s%.1f%%%s)\n" "$_n" "$_p" "$_c" "$_col" "$_sym" "$_abs" "$NC"
  }

  log_summary_header "COMPARISON WITH PREVIOUS ($_pts)"
  printf "\n%sCPU:%s\n" "$CYAN" "$NC"
  _compare "Single-Thread" "$cpu_events_single" "$_pcs" 1
  _compare "Multi-Thread" "$cpu_events_multi" "$_pcm" 1
  printf "\n%sDisk (MB/s):%s\n" "$CYAN" "$NC"
  _compare "Write Buffered" "$disk_write_buffered_mb_s" "$_dwb" 1
  _compare "Write Direct" "$disk_write_direct_mb_s" "$_dwd" 1
  _compare "Read Direct" "$disk_read_mb_s" "$_dr" 1
  printf "\n%sNetwork:%s\n" "$CYAN" "$NC"
  _compare "Download" "$network_download_mbps" "$_nd" 1
  _compare "Upload" "$network_upload_mbps" "$_nu" 1
  _compare "Latency" "$network_ping_ms" "$_np" 0
}

# ============================================================================
# Installation & Dependency Management
# ============================================================================

try_install_speedtest_ookla() {
  _url=$1
  _mgr=$2
  if command -v speedtest >/dev/null 2>&1; then return 0; fi

  if command -v bash >/dev/null 2>&1; then
    if curl -sfS "$_url" | bash; then
      if "$_mgr" install -y speedtest >/dev/null 2>&1; then
        INSTALL_SPEEDTEST_CLI="ookla"
        printf "%s✓%s Ookla Speedtest installed\n" "$GREEN" "$NC"
        return 0
      fi
    fi
  fi
  return 1
}

install_speedtest_python() {
  if command -v speedtest-cli >/dev/null 2>&1; then
    INSTALL_SPEEDTEST_CLI="python"
    return 0
  fi

  if ! command -v pip3 >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      apt-get install -y python3-pip >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y python3-pip >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
      yum install -y python3-pip >/dev/null 2>&1
    fi
  fi

  if command -v pip3 >/dev/null 2>&1; then
    pip3 install --break-system-packages speedtest-cli >/dev/null 2>&1 || \
    pip3 install speedtest-cli >/dev/null 2>&1 || true
    if command -v speedtest-cli >/dev/null 2>&1; then
      INSTALL_SPEEDTEST_CLI="python"
      printf "%s✓%s speedtest-cli (Python) installed\n" "$GREEN" "$NC"
      return 0
    fi
  fi
  return 1
}

check_deps() {
  _missing_core=""
  for t in sysbench bc sqlite3 curl; do
    command -v "$t" >/dev/null 2>&1 || _missing_core="$_missing_core $t"
  done

  _missing_net=0
  if ! command -v speedtest >/dev/null 2>&1 && ! command -v speedtest-cli >/dev/null 2>&1; then
    _missing_net=1
  fi

  if [ -z "$_missing_core" ] && [ "$_missing_net" -eq 0 ]; then
    log_info "Dependencies: OK"
    return 0
  fi

  printf "\n%sMissing Dependencies:%s%s" "$BLUE" "$NC" "$_missing_core"
  [ "$_missing_net" -eq 1 ] && printf " speedtest"
  printf "\n"

  if [ "$(id -u)" -ne 0 ]; then
    error_exit "Missing dependencies. Run as root/sudo to install."
  fi

  if yes_no_prompt "Install missing dependencies?"; then
    log_info "Installing Dependencies"

    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -y >/dev/null 2>&1
      [ -n "$_missing_core" ] && apt-get install -y $_missing_core >/dev/null 2>&1
      if [ "$_missing_net" -eq 1 ]; then
        try_install_speedtest_ookla "https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh" "apt-get" || install_speedtest_python
      fi
    elif command -v dnf >/dev/null 2>&1; then
      [ -n "$_missing_core" ] && dnf install -y $_missing_core >/dev/null 2>&1
      if [ "$_missing_net" -eq 1 ]; then
        try_install_speedtest_ookla "https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh" "dnf" || install_speedtest_python
      fi
    elif command -v yum >/dev/null 2>&1; then
      [ -n "$_missing_core" ] && yum install -y $_missing_core >/dev/null 2>&1
      if [ "$_missing_net" -eq 1 ]; then
        try_install_speedtest_ookla "https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh" "yum" || install_speedtest_python
      fi
    else
      error_exit "Unsupported package manager. Install manually."
    fi
    printf "%s✓%s Installation complete.\n" "$GREEN" "$NC"
  else
    error_exit "Cannot proceed without dependencies."
  fi
}

# ============================================================================
# Benchmarks
# ============================================================================

parse_dd() {
  printf '%s\n' "$1" | tail -n 1 | awk '{
    rate=""; unit="";
    for(i=1;i<=NF;i++) {
      if($i ~ /[0-9]/ && $(i+1) ~ /^[GM]B\/s$/) { rate=$i; unit=$(i+1); break }
    }
    if(unit=="GB/s") print int(rate*1024); else if(unit=="MB/s") print int(rate); else print "0";
  }'
}

run_disk_benchmarks() {
  log_section "Disk Benchmark: Target $DISK_DIR"

  if [ ! -d "$DISK_DIR" ]; then
    printf "%sError: Directory '%s' does not exist. Skipping disk tests.%s\n" "$RED" "$DISK_DIR" "$NC"
    return
  fi

  if [ ! -w "$DISK_DIR" ]; then
    printf "%sError: Directory '%s' is not writable. Skipping disk tests.%s\n" "$RED" "$DISK_DIR" "$NC"
    return
  fi

  # Optional warning if DISK_DIR is on tmpfs (Linux-specific, best-effort)
  if command -v df >/dev/null 2>&1; then
    _fstype=$(df -T "$DISK_DIR" 2>/dev/null | awk 'NR==2 {print $2}')
    if [ "$_fstype" = "tmpfs" ]; then
      printf "%sWarning: %s appears to be tmpfs (RAM). Disk benchmark will measure RAM speed, not persistent storage.%s\n" "$YELLOW" "$DISK_DIR" "$NC"
    fi
  fi

  log_info "Write Buffered (1GiB)"
  if _out=$(dd if=/dev/zero of="$TEST_FILE" bs=1M count=1024 conv=fdatasync status=progress 2>&1); then
    disk_write_buffered_mb_s=$(parse_dd "$_out")
    printf "Speed: %s MB/s\n" "$disk_write_buffered_mb_s"
  else
    printf "%sFailed%s\n" "$RED" "$NC"
  fi

  log_info "Write Direct (1GiB)"
  if _out=$(dd if=/dev/zero of="$TEST_FILE" bs=1M count=1024 oflag=direct status=progress 2>&1); then
    disk_write_direct_mb_s=$(parse_dd "$_out")
    printf "Speed: %s MB/s\n" "$disk_write_direct_mb_s"
  else
    printf "%sSkipped (Direct I/O not supported)%s\n" "$YELLOW" "$NC"
  fi

  log_info "Read Direct (1GiB)"
  if _out=$(dd if="$TEST_FILE" of=/dev/null bs=1M count=1024 iflag=direct status=progress 2>&1); then
    disk_read_mb_s=$(parse_dd "$_out")
    printf "Speed: %s MB/s\n" "$disk_read_mb_s"
  else
    printf "%sFailed%s\n" "$RED" "$NC"
  fi
}

run_cpu_benchmarks() {
  log_section "CPU Benchmark"
  printf "Single Thread... "
  _out=$(sysbench cpu --time=10 --threads=1 --cpu-max-prime=20000 run)
  cpu_events_single=$(printf '%s\n' "$_out" | awk -F': ' '/events per second:/ {print $2; exit}')
  printf "%s events/s\n" "$cpu_events_single"

  _cores=$(nproc 2>/dev/null || echo 1)
  printf "Multi Thread (%s)... " "$_cores"
  _out=$(sysbench cpu --time=10 --threads="$_cores" --cpu-max-prime=20000 run)
  cpu_events_multi=$(printf '%s\n' "$_out" | awk -F': ' '/events per second:/ {print $2; exit}')
  printf "%s events/s\n" "$cpu_events_multi"
}

extract_speed() {
  echo "$1" | awk -v p="$2" '$0 ~ p { for(i=1;i<=NF;i++) { if($i~/^[0-9]+(\.[0-9]+)?$/) { print $i; exit } } }' | head -n 1
}

run_network_benchmark() {
  log_section "Network Speed Test"
  _out=""
  if command -v speedtest >/dev/null 2>&1; then
    if ! _out=$(run_with_timeout 300 speedtest --accept-license --accept-gdpr 2>&1); then printf "%sFailed%s\n" "$RED" "$NC"; return 1; fi
    printf "%s\n" "$_out"
    network_download_mbps=$(extract_speed "$_out" "Download:")
    network_upload_mbps=$(extract_speed "$_out" "Upload:")
    network_ping_ms=$(extract_speed "$_out" "Latency:")
  elif command -v speedtest-cli >/dev/null 2>&1; then
    if ! _out=$(run_with_timeout 300 speedtest-cli --simple 2>&1); then printf "%sFailed%s\n" "$RED" "$NC"; return 1; fi
    printf "%s\n" "$_out"
    network_download_mbps=$(extract_speed "$_out" "^Download:")
    network_upload_mbps=$(extract_speed "$_out" "^Upload:")
    network_ping_ms=$(extract_speed "$_out" "^Ping:")
  else
    printf "%sNo speedtest tool found.%s\n" "$RED" "$NC"; return 1
  fi
  [ -z "$network_download_mbps" ] && network_download_mbps="N/A"
  [ -z "$network_upload_mbps" ] && network_upload_mbps="N/A"
  [ -z "$network_ping_ms" ] && network_ping_ms="N/A"
}

# ============================================================================
# Main
# ============================================================================

main() {
  while [ "$#" -gt 0 ]; do
    case $1 in
      --disk-dir)
        shift; [ "$#" -gt 0 ] || error_exit "--disk-dir requires arg"
        DISK_DIR=$1; shift ;;
      -s|--save) OPT_SAVE=1; shift ;;
      -c|--compare) OPT_SAVE=1; OPT_COMPARE=1; shift ;;
      -l|--list) OPT_LIST=1; shift ;;
      -h|--help)
        cat <<USAGE
VPS Benchmark Script
Usage: $(basename "$0") [OPTIONS]
Options:
  --disk-dir DIR   Directory for disk tests (default: \$BENCH_TMPDIR or .)
  -s, --save       Save to SQLite
  -c, --compare    Save and compare
  -l, --list       List runs
USAGE
        exit 0 ;;
      *) error_exit "Unknown option: $1" ;;
    esac
  done

  [ "$OPT_LIST" -eq 1 ] && list_benchmarks

  # Create filename AFTER args are parsed
  _ts_suffix=$(date +%s 2>/dev/null || date +%Y%m%d%H%M%S)
  TEST_FILE="${DISK_DIR}/vps_bench_testfile_$$-${_ts_suffix}"

  check_deps

  log_info "System Information"
  printf "Hostname: %s\n" "$(hostname)"
  uptime | awk -F'( |,|:)+' '{if ($6=="up") print "Uptime: " $7"d "$9"h "$10"m"; else print "Uptime: " $6"d "$8"h "$9"m"}' 2>/dev/null || uptime
  if command -v lscpu >/dev/null 2>&1; then
    lscpu | grep -E '^Model name:|^CPU\(s\):|^Thread\(s\) per core:' | sed 's/^[ \t]*//'
  fi
  if command -v free >/dev/null 2>&1; then
    printf "\nMemory:\n"
    free -h
  fi
  if command -v lsblk >/dev/null 2>&1; then
    printf "\nDisk Map:\n"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT 2>/dev/null || true
  fi

  log_section "Tool Versions"
  sysbench --version 2>/dev/null || printf "sysbench: N/A\n"
  if command -v speedtest >/dev/null 2>&1; then
      speedtest --version | head -n 1
  elif command -v speedtest-cli >/dev/null 2>&1; then
      speedtest-cli --version | head -n 1
  fi

  log_info "Starting Benchmarks"
  run_cpu_benchmarks
  run_disk_benchmarks
  run_network_benchmark || true

  _ts=$(date '+%Y-%m-%d %H:%M:%S')
  _ts_iso=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  log_summary_header "FINAL RESULTS SUMMARY"

  printf "\n%sExecution Details:%s\n" "$BLUE" "$NC"
  printf "  %-20s: %s\n" "Hostname" "$(hostname)"
  printf "  %-20s: %s\n" "Timestamp" "$_ts"
  printf "  %-20s: %s%s%s\n" "Status" "$GREEN" "Completed" "$NC"

  printf "\n%sCPU Performance (sysbench):%s\n" "$CYAN" "$NC"
  _s_cpu_s=$(get_status_indicator "$cpu_events_single")
  _s_cpu_m=$(get_status_indicator "$cpu_events_multi")
  printf "  %-20s [%s]: %s%s%s events/sec\n" "Single-Thread" "$_s_cpu_s" "$GREEN" "$cpu_events_single" "$NC"
  printf "  %-20s [%s]: %s%s%s events/sec\n" "Multi-Thread" "$_s_cpu_m" "$GREEN" "$cpu_events_multi" "$NC"

  printf "\n%sDisk Performance (dd 1GiB):%s\n" "$CYAN" "$NC"
  printf "  %-20s: %s\n" "Test Path" "$DISK_DIR"
  _s_dwb=$(get_status_indicator "$disk_write_buffered_mb_s")
  _s_dwd=$(get_status_indicator "$disk_write_direct_mb_s")
  _s_dr=$(get_status_indicator "$disk_read_mb_s")
  printf "  %-20s [%s]: %s%s%s MB/s\n" "Write (Buffered)" "$_s_dwb" "$GREEN" "$disk_write_buffered_mb_s" "$NC"
  printf "  %-20s [%s]: %s%s%s MB/s\n" "Write (Direct)" "$_s_dwd" "$GREEN" "$disk_write_direct_mb_s" "$NC"
  printf "  %-20s [%s]: %s%s%s MB/s\n" "Read (Direct)" "$_s_dr" "$GREEN" "$disk_read_mb_s" "$NC"

  printf "\n%sNetwork Performance (speedtest):%s\n" "$CYAN" "$NC"
  _s_nd=$(get_status_indicator "$network_download_mbps")
  _s_nu=$(get_status_indicator "$network_upload_mbps")
  _s_np=$(get_status_indicator "$network_ping_ms")
  printf "  %-20s [%s]: %s%s%s Mbps\n" "Download" "$_s_nd" "$GREEN" "$network_download_mbps" "$NC"
  printf "  %-20s [%s]: %s%s%s Mbps\n" "Upload" "$_s_nu" "$GREEN" "$network_upload_mbps" "$NC"
  printf "  %-20s [%s]: %s%s%s ms\n" "Latency" "$_s_np" "$GREEN" "$network_ping_ms" "$NC"

  if [ "$OPT_SAVE" -eq 1 ]; then
    init_database
    save_to_database "$_ts_iso" "$(hostname)"
  fi
  if [ "$OPT_COMPARE" -eq 1 ]; then
    compare_with_previous "$(hostname)"
  fi
}

main "$@"
