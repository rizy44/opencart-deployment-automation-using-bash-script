#!/usr/bin/env bash

set -o pipefail

deploy_all() {
  require_root
  assert_ubuntu

  log_info "Starting deployment for OpenCart stack on Ubuntu."

  install_dependencies
  setup_database
  install_opencart
  configure_nginx_site
  restart_services
  post_deploy_check

  log_info "Deployment completed. Access site at: http://${DOMAIN}"
}

install_dependencies() {
  log_info "Installing required Ubuntu packages."

  export DEBIAN_FRONTEND=noninteractive

  apt-get update -y
  apt-get install -y \
    nginx \
    mariadb-server \
    curl \
    unzip \
    rsync \
    tar \
    zstd \
    gzip \
    jq \
    ca-certificates \
    php-fpm \
    php-cli \
    php-common \
    php-mysql \
    php-curl \
    php-gd \
    php-intl \
    php-mbstring \
    php-xml \
    php-zip \
    php-bcmath \
    php-soap

  systemctl enable nginx
  systemctl enable mariadb
}

setup_database() {
  log_info "Configuring MariaDB database and user."

  local sql
  sql=$(cat <<EOF
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'${DB_HOST}' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'${DB_HOST}';
FLUSH PRIVILEGES;
EOF
)

  mariadb -u root -e "${sql}"
}

download_opencart_archive() {
  local target_zip="$1"

  if [[ -n "${OPENCART_ZIP_URL}" ]]; then
    curl -fsSL "${OPENCART_ZIP_URL}" -o "${target_zip}"
    return
  fi

  local version_url="https://github.com/opencart/opencart/releases/download/${OPENCART_VERSION}/opencart-${OPENCART_VERSION}.zip"
  curl -fsSL "${version_url}" -o "${target_zip}"
}

install_opencart() {
  log_info "Downloading and preparing OpenCart files."

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  local zip_file="${tmp_dir}/opencart.zip"

  download_opencart_archive "${zip_file}"
  unzip -q "${zip_file}" -d "${tmp_dir}"

  ensure_dir "${WEB_ROOT}"

  # OpenCart package has upload/ as the actual web root content.
  if [[ -d "${tmp_dir}/upload" ]]; then
    rsync -a --delete "${tmp_dir}/upload/" "${WEB_ROOT}/"
  elif [[ -d "${tmp_dir}/opencart/upload" ]]; then
    rsync -a --delete "${tmp_dir}/opencart/upload/" "${WEB_ROOT}/"
  else
    log_error "Unable to find OpenCart upload directory in archive."
    exit 1
  fi

  if [[ -f "${WEB_ROOT}/config-dist.php" ]]; then
    cp -f "${WEB_ROOT}/config-dist.php" "${WEB_ROOT}/config.php"
  fi

  if [[ -f "${WEB_ROOT}/admin/config-dist.php" ]]; then
    cp -f "${WEB_ROOT}/admin/config-dist.php" "${WEB_ROOT}/admin/config.php"
  fi

  configure_opencart_files

  chown -R "${APP_USER}:${APP_GROUP}" "${WEB_ROOT}"
  find "${WEB_ROOT}" -type d -exec chmod 755 {} \;
  find "${WEB_ROOT}" -type f -exec chmod 644 {} \;

  rm -rf "${tmp_dir}"
}

configure_opencart_files() {
  local http_url="http://${DOMAIN}/"
  local https_url="https://${DOMAIN}/"

  if [[ -f "${WEB_ROOT}/config.php" ]]; then
    sed -i "s|define('HTTP_SERVER'.*|define('HTTP_SERVER', '${http_url}');|" "${WEB_ROOT}/config.php" || true
    sed -i "s|define('HTTPS_SERVER'.*|define('HTTPS_SERVER', '${https_url}');|" "${WEB_ROOT}/config.php" || true
  fi

  if [[ -f "${WEB_ROOT}/admin/config.php" ]]; then
    sed -i "s|define('HTTP_SERVER'.*|define('HTTP_SERVER', '${http_url}admin/');|" "${WEB_ROOT}/admin/config.php" || true
    sed -i "s|define('HTTPS_SERVER'.*|define('HTTPS_SERVER', '${https_url}admin/');|" "${WEB_ROOT}/admin/config.php" || true
  fi
}

configure_nginx_site() {
  log_info "Configuring Nginx virtual host."

  local available="/etc/nginx/sites-available/${SITE_NAME}.conf"
  local enabled="/etc/nginx/sites-enabled/${SITE_NAME}.conf"
  local php_sock="${PHP_FPM_SOCK}"

  cat > "${available}" <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    root ${WEB_ROOT};
    index index.php index.html index.htm;

    access_log /var/log/nginx/${SITE_NAME}_access.log;
    error_log /var/log/nginx/${SITE_NAME}_error.log;

    location / {
        try_files \$uri \$uri/ /index.php?route=common/home;
    }

    location ~ \\.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${php_sock};
    }

    location ~ /\\.ht {
        deny all;
    }
}
EOF

  ln -sfn "${available}" "${enabled}"
  rm -f /etc/nginx/sites-enabled/default

  nginx -t
}

restart_services() {
  log_info "Restarting services."
  systemctl restart mariadb
  systemctl restart "${PHP_FPM_SERVICE}"
  systemctl restart nginx
}

post_deploy_check() {
  log_info "Running post-deployment checks."

  systemctl is-active --quiet nginx
  systemctl is-active --quiet mariadb
  systemctl is-active --quiet "${PHP_FPM_SERVICE}"

  if curl -I -s "http://127.0.0.1" >/dev/null; then
    log_info "HTTP check passed on localhost."
  else
    log_warn "HTTP check failed on localhost; verify domain and firewall settings."
  fi
}
