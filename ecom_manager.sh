#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/deploy.sh
source "${SCRIPT_DIR}/lib/deploy.sh"
# shellcheck source=lib/analyze.sh
source "${SCRIPT_DIR}/lib/analyze.sh"
# shellcheck source=lib/backup.sh
source "${SCRIPT_DIR}/lib/backup.sh"

print_help() {
  cat <<'EOF'
Usage:
  ./ecom_manager.sh <command> [options]

Commands:
  deploy                Install and configure full OpenCart stack on Ubuntu
  analyze               Generate website structure and file extension reports
  backup-full           Create full backup (files + database) with compression
  backup-incremental    Create incremental file snapshot + compressed DB dump
  restore-full <path>   Restore from a full backup directory
  help                  Show this help

Environment:
  Copy config/env.conf.example to config/env.conf and edit values.
EOF
}

main() {
  local command="${1:-help}"

  load_config

  case "${command}" in
    deploy)
      shift
      deploy_all "$@"
      ;;
    analyze)
      shift
      run_analysis "$@"
      ;;
    backup-full)
      shift
      backup_full "$@"
      ;;
    backup-incremental)
      shift
      backup_incremental "$@"
      ;;
    restore-full)
      shift
      restore_full "$@"
      ;;
    help|-h|--help)
      print_help
      ;;
    *)
      log_error "Unknown command: ${command}"
      print_help
      exit 1
      ;;
  esac
}

main "$@"
