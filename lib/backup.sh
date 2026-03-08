#!/usr/bin/env bash

set -o pipefail

compression_ext() {
  if command -v zstd >/dev/null 2>&1; then
    echo "zst"
  else
    echo "gz"
  fi
}

compress_file() {
  local input_file="$1"
  local output_file="$2"

  if command -v zstd >/dev/null 2>&1; then
    zstd -q -19 -T0 -f "${input_file}" -o "${output_file}"
  else
    gzip -c -9 "${input_file}" > "${output_file}"
  fi
}

cleanup_old_dirs() {
  local base_dir="$1"
  local keep="$2"

  if [[ ! -d "${base_dir}" ]]; then
    return
  fi

  mapfile -t old_dirs < <(find "${base_dir}" -mindepth 1 -maxdepth 1 -type d | sort)

  local count="${#old_dirs[@]}"
  if (( count <= keep )); then
    return
  fi

  local remove_count=$(( count - keep ))
  local i
  for (( i=0; i<remove_count; i++ )); do
    rm -rf "${old_dirs[$i]}"
  done
}

backup_full() {
  require_root
  require_commands mysqldump tar sha256sum date

  if [[ ! -d "${WEB_ROOT}" ]]; then
    log_error "WEB_ROOT not found: ${WEB_ROOT}"
    exit 1
  fi

  local ts
  ts="$(date +%Y%m%d_%H%M%S)"

  local full_root="${BACKUP_ROOT}/full"
  local dest_dir="${full_root}/${ts}"
  local ext
  ext="$(compression_ext)"

  ensure_dir "${dest_dir}"

  local files_tar="${dest_dir}/website_files.tar"
  local files_comp="${dest_dir}/website_files.tar.${ext}"
  local db_sql="${dest_dir}/database.sql"
  local db_comp="${dest_dir}/database.sql.${ext}"
  local metadata="${dest_dir}/metadata.txt"

  log_info "Creating full files archive."
  tar -C "${WEB_ROOT}" -cf "${files_tar}" .
  compress_file "${files_tar}" "${files_comp}"
  rm -f "${files_tar}"

  log_info "Dumping database for full backup."
  mysqldump \
    --single-transaction \
    --quick \
    --lock-tables=false \
    -h "${DB_HOST}" \
    -u "${DB_USER}" \
    "-p${DB_PASSWORD}" \
    "${DB_NAME}" > "${db_sql}"
  compress_file "${db_sql}" "${db_comp}"
  rm -f "${db_sql}"

  {
    echo "mode=full"
    echo "timestamp=${ts}"
    echo "web_root=${WEB_ROOT}"
    echo "db_name=${DB_NAME}"
    echo "files_archive=$(basename "${files_comp}")"
    echo "database_archive=$(basename "${db_comp}")"
  } > "${metadata}"

  (
    cd "${dest_dir}"
    sha256sum ./* > SHA256SUMS
  )

  cleanup_old_dirs "${full_root}" "${RETAIN_FULL}"

  log_info "Full backup created at: ${dest_dir}"
}

backup_incremental() {
  require_root
  require_commands rsync mysqldump sha256sum date

  if [[ ! -d "${WEB_ROOT}" ]]; then
    log_error "WEB_ROOT not found: ${WEB_ROOT}"
    exit 1
  fi

  local ts
  ts="$(date +%Y%m%d_%H%M%S)"

  local inc_root="${BACKUP_ROOT}/incremental"
  local snapshot_root="${inc_root}/snapshots"
  local snapshot_dir="${snapshot_root}/${ts}"
  local current_link="${snapshot_root}/current"
  local ext
  ext="$(compression_ext)"

  ensure_dir "${snapshot_dir}/files"

  local last_snapshot=""
  if [[ -L "${current_link}" ]]; then
    last_snapshot="$(readlink -f "${current_link}")"
  fi

  log_info "Creating incremental website snapshot."
  if [[ -n "${last_snapshot}" && -d "${last_snapshot}/files" ]]; then
    rsync -ani --delete --link-dest="${last_snapshot}/files" "${WEB_ROOT}/" "${snapshot_dir}/files/" > "${snapshot_dir}/changes.txt" || true
    rsync -a --delete --link-dest="${last_snapshot}/files" "${WEB_ROOT}/" "${snapshot_dir}/files/"
  else
    rsync -a --delete "${WEB_ROOT}/" "${snapshot_dir}/files/"
    echo "First incremental snapshot contains full file set." > "${snapshot_dir}/changes.txt"
  fi

  log_info "Dumping database for incremental backup."
  local db_sql="${snapshot_dir}/database.sql"
  local db_comp="${snapshot_dir}/database.sql.${ext}"

  mysqldump \
    --single-transaction \
    --quick \
    --lock-tables=false \
    -h "${DB_HOST}" \
    -u "${DB_USER}" \
    "-p${DB_PASSWORD}" \
    "${DB_NAME}" > "${db_sql}"

  compress_file "${db_sql}" "${db_comp}"
  rm -f "${db_sql}"

  {
    echo "mode=incremental"
    echo "timestamp=${ts}"
    echo "web_root=${WEB_ROOT}"
    echo "base_snapshot=${last_snapshot:-none}"
    echo "db_archive=$(basename "${db_comp}")"
  } > "${snapshot_dir}/metadata.txt"

  (
    cd "${snapshot_dir}"
    sha256sum metadata.txt "$(basename "${db_comp}")" changes.txt > SHA256SUMS
  )

  ln -sfn "${snapshot_dir}" "${current_link}"
  echo "${snapshot_dir}" > "${STATE_DIR}/last_incremental_snapshot"

  cleanup_old_dirs "${snapshot_root}" "${RETAIN_INCREMENTAL}"

  log_info "Incremental snapshot created at: ${snapshot_dir}"
}

restore_full() {
  require_root

  local source_dir="${1:-}"
  if [[ -z "${source_dir}" ]]; then
    log_error "Usage: ./ecom_manager.sh restore-full <full_backup_dir>"
    exit 1
  fi

  if [[ ! -d "${source_dir}" ]]; then
    log_error "Backup directory not found: ${source_dir}"
    exit 1
  fi

  local files_archive
  files_archive="$(find "${source_dir}" -maxdepth 1 -type f -name 'website_files.tar.*' | head -n 1)"
  local db_archive
  db_archive="$(find "${source_dir}" -maxdepth 1 -type f -name 'database.sql.*' | head -n 1)"

  if [[ -z "${files_archive}" || -z "${db_archive}" ]]; then
    log_error "Invalid full backup directory structure."
    exit 1
  fi

  log_info "Restoring files to ${WEB_ROOT}."
  ensure_dir "${WEB_ROOT}"
  find "${WEB_ROOT}" -mindepth 1 -delete

  if [[ "${files_archive}" == *.zst ]]; then
    zstd -dc "${files_archive}" | tar -C "${WEB_ROOT}" -xf -
  else
    gzip -dc "${files_archive}" | tar -C "${WEB_ROOT}" -xf -
  fi

  log_info "Restoring MariaDB database ${DB_NAME}."
  if [[ "${db_archive}" == *.zst ]]; then
    zstd -dc "${db_archive}" | mariadb -h "${DB_HOST}" -u "${DB_USER}" "-p${DB_PASSWORD}" "${DB_NAME}"
  else
    gzip -dc "${db_archive}" | mariadb -h "${DB_HOST}" -u "${DB_USER}" "-p${DB_PASSWORD}" "${DB_NAME}"
  fi

  chown -R "${APP_USER}:${APP_GROUP}" "${WEB_ROOT}"
  log_info "Full restore complete."
}
