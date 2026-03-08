#!/usr/bin/env bash

set -o pipefail

LOG_TS_FORMAT="%Y-%m-%d %H:%M:%S"

log_info() {
  printf '[%s] [INFO] %s\n' "$(date "+${LOG_TS_FORMAT}")" "$*"
}

log_warn() {
  printf '[%s] [WARN] %s\n' "$(date "+${LOG_TS_FORMAT}")" "$*"
}

log_error() {
  printf '[%s] [ERROR] %s\n' "$(date "+${LOG_TS_FORMAT}")" "$*" >&2
}

on_error() {
  local line_no="$1"
  local exit_code="$2"
  log_error "Command failed at line ${line_no} with exit code ${exit_code}."
}

trap 'on_error ${LINENO} $?' ERR

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    log_error "Run this script with sudo or as root."
    exit 1
  fi
}

require_commands() {
  local missing=0
  local cmd
  for cmd in "$@"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      log_error "Missing required command: ${cmd}"
      missing=1
    fi
  done

  if [[ "${missing}" -ne 0 ]]; then
    exit 1
  fi
}

ensure_dir() {
  local dir="$1"
  mkdir -p "${dir}"
}

human_bytes() {
  local bytes="$1"
  local units=(B KB MB GB TB)
  local i=0
  local value="${bytes}"

  while (( value >= 1024 && i < ${#units[@]} - 1 )); do
    value=$(( value / 1024 ))
    ((i++))
  done

  echo "${value}${units[${i}]}"
}

load_config() {
  local script_root
  script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

  local cfg="${script_root}/config/env.conf"
  local cfg_example="${script_root}/config/env.conf.example"

  if [[ -f "${cfg}" ]]; then
    # shellcheck disable=SC1090
    source "${cfg}"
  elif [[ -f "${cfg_example}" ]]; then
    log_warn "config/env.conf not found. Loading defaults from env.conf.example"
    # shellcheck disable=SC1090
    source "${cfg_example}"
  else
    log_error "No config file found. Create config/env.conf from env.conf.example"
    exit 1
  fi

  PROJECT_ROOT="${script_root}"

  ensure_dir "${REPORT_ROOT}"
  ensure_dir "${BACKUP_ROOT}"
  ensure_dir "${STATE_DIR}"
}

ubuntu_major_version() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    if [[ "${ID:-}" == "ubuntu" ]]; then
      echo "${VERSION_ID%%.*}"
      return 0
    fi
  fi
  echo "unknown"
}

assert_ubuntu() {
  local major
  major="$(ubuntu_major_version)"
  if [[ "${major}" == "unknown" ]]; then
    log_error "This script supports Ubuntu only."
    exit 1
  fi
}
