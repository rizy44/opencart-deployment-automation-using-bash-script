#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# End-to-end automation: deploy + analyze + full backup + incremental backup
"${SCRIPT_DIR}/ecom_manager.sh" deploy
"${SCRIPT_DIR}/ecom_manager.sh" analyze
"${SCRIPT_DIR}/ecom_manager.sh" backup-full
"${SCRIPT_DIR}/ecom_manager.sh" backup-incremental

echo "All automation steps completed successfully."
