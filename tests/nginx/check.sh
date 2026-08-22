#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd -- "$repository_root"

readonly quoted_hashed_asset_location='    location ~* "\.[0-9a-f]{8,}\.(?:css|js|mjs|png|jpe?g|gif|webp|avif|svg|ico|woff2?|ttf|otf)$" {'

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
  grep -Fq 'location = /rss.xml' "$file"
  grep -Fq 'location = /sitemap.xml' "$file"
  grep -Fq 'location = /robots.txt' "$file"
  grep -Fq 'location ~* \.data$' "$file"
  grep -Fq 'error_page 418 =404 /__spa-fallback.html' "$file"
  grep -Fq 'public, max-age=31536000, immutable' "$file"
  grep -Fq 'no-cache, max-age=0, must-revalidate' "$file"
  grep -Fq 'no-store' "$file"
done

grep -Fq 'ssl_protocols TLSv1.2 TLSv1.3' config/nginx/portfolio-tls.conf.tftpl
grep -Fq 'Strict-Transport-Security "max-age=300"' config/nginx/portfolio-tls.conf.tftpl
! grep -Fq 'includeSubDomains' config/nginx/portfolio-tls.conf.tftpl
grep -Fq 'Content-Security-Policy-Report-Only' config/nginx/security-headers.conf
! grep -Eq '\$args|\$cookie_|\$http_authorization|\$request_body|"\$request"' config/nginx/nginx.conf

printf '%s\n' 'Nginx contract checks passed'
