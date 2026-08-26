#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd -- "$repository_root"
file=config/nginx/identity-runtime.conf.tftpl
[[ "$(grep -Fxc '    location ^~ /auth/ {' "$file")" == 1 ]]
[[ "$(grep -Fxc '    location ^~ /api/ {' "$file")" == 1 ]]
[[ "$(grep -Fxc '    server_name identity.${base_domain};' "$file")" == 1 ]]
[[ "$(grep -Fxc '        proxy_pass http://identity_bff;' "$file")" == 2 ]]
[[ "$(grep -Fxc '        proxy_pass http://identity_api;' "$file")" == 1 ]]
! grep -Eq 'server_name[[:space:]]+auth[.]|proxy_pass[^;]*auth[.]' "$file"
grep -Fq 'return 308 https://${base_domain}$request_uri;' "$file"
grep -Fq 'error_page 418 =404 /__spa-fallback.html;' "$file"
grep -Fq 'Content-Security-Policy-Report-Only' config/nginx/security-headers.conf
! grep -Eq '\$args|\$cookie_|\$http_authorization|\$request_body|"\$request"' config/nginx/nginx.conf "$file"
printf 'Identity Nginx source checks passed.\n'
