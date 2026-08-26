#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd -- "$repository_root"

readonly quoted_hashed_asset_location='    location ~* "\.[0-9a-f]{8,}\.(?:css|js|mjs|png|jpe?g|gif|webp|avif|svg|ico|woff2?|ttf|otf)$" {'
readonly security_headers='config/nginx/security-headers.conf'
readonly nginx_config='config/nginx/nginx.conf'

location_block() {
  local file="$1"
  local location="$2"

  awk -v location="$location" '
    $0 == location {
      active = 1
    }
    active {
      print
      opens = gsub(/\{/, "{")
      closes = gsub(/\}/, "}")
      depth += opens - closes
      if (depth == 0) {
        exit
      }
    }
  ' "$file"
}

for file in config/nginx/portfolio-http.conf.tftpl config/nginx/portfolio-tls.conf.tftpl; do
  quoted_hashed_asset_count="$(grep -Fxc "$quoted_hashed_asset_location" "$file" || true)"
  if [[ "$quoted_hashed_asset_count" -ne 1 ]]; then
    printf 'expected exactly one quoted hashed-asset location in %s\n' "$file" >&2
    exit 1
  fi
  if grep -Eq '^[[:space:]]*location[[:space:]]+~\*[[:space:]]+[^"]*\\\.\[0-9a-f\]\{8,\}' "$file"; then
    printf 'unquoted hashed-asset location found in %s\n' "$file" >&2
    exit 1
  fi
  grep -Fq 'location = /healthz' "$file"
  grep -Fq 'location ^~ /.well-known/acme-challenge/' "$file"
  [[ "$(grep -Fxc '    location = /rss.xml {' "$file")" == "1" ]]
  rss_block="$(location_block "$file" '    location = /rss.xml {')"
  [[ "$(grep -Fxc '        types { }' <<<"$rss_block")" == "1" ]]
  [[ "$(grep -Fxc '        default_type "application/rss+xml; charset=utf-8";' <<<"$rss_block")" == "1" ]]
  [[ "$(grep -Fxc '    location = /sitemap.xml {' "$file")" == "1" ]]
  sitemap_block="$(location_block "$file" '    location = /sitemap.xml {')"
  [[ "$(grep -Fxc '        types { }' <<<"$sitemap_block")" == "1" ]]
  [[ "$(grep -Fxc '        default_type "application/xml; charset=utf-8";' <<<"$sitemap_block")" == "1" ]]
  grep -Fq 'location = /robots.txt' "$file"
  grep -Fq 'location ~* \.data$' "$file"
  grep -Fq 'error_page 418 =404 /__spa-fallback.html' "$file"
  grep -Fq 'public, max-age=31536000, immutable' "$file"
  grep -Fq 'no-cache, max-age=0, must-revalidate' "$file"
  grep -Fq 'no-store' "$file"
done

[[ "$(grep -Ec '^[[:space:]]*add_header_inherit[[:space:]]+merge;[[:space:]]*$' "$security_headers")" == "1" ]]
! grep -Eq '^[[:space:]]*add_header_inherit[[:space:]]+off;[[:space:]]*$' "$security_headers"
[[ "$(grep -Fxc 'add_header X-Content-Type-Options "nosniff" always;' "$security_headers")" == "1" ]]
[[ "$(grep -Fxc 'add_header Referrer-Policy "strict-origin-when-cross-origin" always;' "$security_headers")" == "1" ]]
[[ "$(grep -Fxc 'add_header Permissions-Policy "camera=(), geolocation=(), microphone=()" always;' "$security_headers")" == "1" ]]
[[ "$(grep -Fc 'add_header Content-Security-Policy-Report-Only ' "$security_headers")" == "1" ]]

[[ "$(grep -Fxc '        image/avif avif;' "$nginx_config")" == "1" ]]
grep -Fq '    include /etc/nginx/mime.types;' "$nginx_config"
grep -Fq '    default_type application/octet-stream;' "$nginx_config"

grep -Fq 'ssl_protocols TLSv1.2 TLSv1.3' config/nginx/portfolio-tls.conf.tftpl
[[ "$(grep -Fxc '    add_header Strict-Transport-Security "max-age=300" always;' config/nginx/portfolio-tls.conf.tftpl)" == "2" ]]
! grep -Fq 'includeSubDomains' config/nginx/portfolio-tls.conf.tftpl
! grep -Eq '\$args|\$cookie_|\$http_authorization|\$request_body|"\$request"' "$nginx_config"

readonly runtime_configurator='deploy/ssm/configure-runtime.sh.tftpl'
nginx_test_line="$(grep -nF 'nginx -t' "$runtime_configurator" | tail -n 1 | cut -d: -f1)"
nginx_enable_line="$(grep -nF 'systemctl enable nginx.service' "$runtime_configurator" | cut -d: -f1)"
nginx_active_line="$(grep -nF 'if systemctl is-active --quiet nginx.service; then' "$runtime_configurator" | cut -d: -f1)"
nginx_reload_line="$(grep -nF '  systemctl reload nginx.service' "$runtime_configurator" | cut -d: -f1)"
nginx_start_line="$(grep -nF '  systemctl start nginx.service' "$runtime_configurator" | cut -d: -f1)"

[[ -n "$nginx_test_line" && -n "$nginx_enable_line" && -n "$nginx_active_line" ]]
[[ -n "$nginx_reload_line" && -n "$nginx_start_line" ]]
((nginx_test_line < nginx_enable_line))
((nginx_enable_line < nginx_active_line))
((nginx_active_line < nginx_reload_line))
((nginx_reload_line < nginx_start_line))

bash tests/nginx/check-identity.sh
printf '%s\n' 'Nginx contract checks passed'
