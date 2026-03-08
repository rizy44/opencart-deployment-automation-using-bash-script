#!/usr/bin/env bash

set -o pipefail

run_analysis() {
  require_commands find awk sort numfmt

  if [[ ! -d "${WEB_ROOT}" ]]; then
    log_error "WEB_ROOT not found: ${WEB_ROOT}"
    exit 1
  fi

  ensure_dir "${REPORT_ROOT}"

  local ts
  ts="$(date +%Y%m%d_%H%M%S)"

  local summary_file="${REPORT_ROOT}/${ts}_summary.txt"
  local csv_file="${REPORT_ROOT}/${ts}_extensions.csv"
  local json_file="${REPORT_ROOT}/${ts}_extensions.json"

  log_info "Collecting file and directory statistics from ${WEB_ROOT}."

  local file_count
  local dir_count
  local total_size

  file_count="$(find "${WEB_ROOT}" -type f | wc -l | awk '{print $1}')"
  dir_count="$(find "${WEB_ROOT}" -type d | wc -l | awk '{print $1}')"
  total_size="$(du -sb "${WEB_ROOT}" | awk '{print $1}')"

  {
    echo "timestamp=${ts}"
    echo "web_root=${WEB_ROOT}"
    echo "total_files=${file_count}"
    echo "total_directories=${dir_count}"
    echo "total_size_bytes=${total_size}"
    echo "total_size_human=$(numfmt --to=iec "${total_size}")"
  } > "${summary_file}"

  echo "extension,count,total_bytes,total_human" > "${csv_file}"

  # Aggregate by extension with a single pass through all files.
  find "${WEB_ROOT}" -type f -printf '%f\t%s\n' | awk -F'\t' '
    function ext_of(name,   n, parts, ext) {
      n = split(name, parts, ".")
      if (n <= 1) {
        return "no_extension"
      }
      if (parts[1] == "" && n == 2) {
        return "no_extension"
      }
      ext = tolower(parts[n])
      if (ext == "") {
        return "no_extension"
      }
      return ext
    }
    {
      ext = ext_of($1)
      count[ext] += 1
      bytes[ext] += $2
    }
    END {
      for (e in count) {
        print e "," count[e] "," bytes[e]
      }
    }
  ' | sort -t',' -k3,3nr | while IFS=',' read -r ext cnt bytes; do
    local_human="$(numfmt --to=iec "${bytes}")"
    echo "${ext},${cnt},${bytes},${local_human}" >> "${csv_file}"
  done

  awk -F',' '
    NR==1 {next}
    {
      printf "%s{\"extension\":\"%s\",\"count\":%s,\"total_bytes\":%s}", (n++ ? "," : ""), $1, $2, $3
    }
    END {print ""}
  ' "${csv_file}" | {
    echo "["
    cat
    echo "]"
  } > "${json_file}"

  log_info "Analysis complete."
  log_info "Summary report: ${summary_file}"
  log_info "CSV report: ${csv_file}"
  log_info "JSON report: ${json_file}"
}
