#!/usr/bin/env bash
set -euo pipefail

# Colours
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

# Global variables
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_FILE="${SCRIPT_DIR}/pangolin_dd_testfile"
INSTALL_SPEEDTEST_CLI="ookla"

# Error handling
error_exit() {
  printf "${RED}Error: %s${NC}\n" "$1" >&2
  exit 1
}

log_info() {
  printf "${GREEN}=== %s ===${NC}\n" "$1"
}

log_section() {
  printf "\n${YELLOW}%s${NC}\n" "$1"
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
lscpu | grep -E 'Model name|CPU\(s\)|Thread|Core|MHz'
printf "\nMemory:\n"
free -h
printf "\nDisk:\n"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT

# Install dependencies based on package manager
log_section "Installing dependencies (sysbench + speedtest)"

install_debian_based() {
  apt-get update -y || error_exit "Failed to update apt cache"
  apt-get install -y sysbench curl ca-certificates || error_exit "Failed to install base packages"

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
  dnf install -y sysbench curl ca-certificates || true

  if ! command -v sysbench &>/dev/null; then
    dnf install -y epel-release && dnf install -y sysbench || error_exit "Failed to install sysbench"
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
  yum install -y sysbench curl ca-certificates || error_exit "Failed to install base packages"

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
  error_exit "Unsupported package manager. Please install sysbench and speedtest manually."
fi

# Display tool versions
log_section "Tool Versions"
sysbench --version || printf "${YELLOW}Warning: sysbench not available${NC}\n"

if command -v speedtest &>/dev/null; then
  speedtest --version || true
elif command -v speedtest-cli &>/dev/null; then
  speedtest-cli --version || true
else
  printf "${YELLOW}Warning: No speedtest tool available${NC}\n"
fi

# CPU Benchmarks
log_section "CPU Benchmark: Single Thread (time=10s, max-prime=20000)"
sysbench cpu --time=10 --threads=1 --cpu-max-prime=20000 run | grep -E "total time|events per second|Latency" || error_exit "Single-thread CPU benchmark failed"

cpu_count=$(nproc)
log_section "CPU Benchmark: Multi Thread (${cpu_count} threads, time=10s, max-prime=20000)"
sysbench cpu --time=10 --threads="${cpu_count}" --cpu-max-prime=20000 run | grep -E "total time|events per second|Latency" || error_exit "Multi-thread CPU benchmark failed"

# Disk Benchmarks
log_section "Disk Write (1GiB, buffered+flush)"
if dd if=/dev/zero of="${TEST_FILE}" bs=1M count=1024 conv=fdatasync status=progress 2>&1; then
  printf "${GREEN}✓${NC} Buffered disk write complete\n"
else
  printf "${RED}✗${NC} Buffered disk write failed\n"
fi

log_section "Disk Write (1GiB, direct I/O)"
if dd if=/dev/zero of="${TEST_FILE}" bs=1M count=1024 oflag=direct status=progress 2>&1; then
  printf "${GREEN}✓${NC} Direct I/O disk write complete\n"
else
  printf "${YELLOW}Warning: Direct I/O disk write not supported or failed${NC}\n"
fi

# Network Speed Test
log_section "Network Speed Test (${INSTALL_SPEEDTEST_CLI})"

run_speedtest() {
  if command -v speedtest &>/dev/null; then
    speedtest --accept-license --accept-gdpr -f json 2>/dev/null || speedtest --accept-license --accept-gdpr || return 1
  elif command -v speedtest-cli &>/dev/null; then
    speedtest-cli --simple || return 1
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

# Final message
log_info "Benchmarking Complete"
printf "Test file location: ${TEST_FILE}\n"
printf "System benchmarking completed successfully.\n"
