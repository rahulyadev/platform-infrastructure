#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

base_url="${1:-http://127.0.0.1}"
release_root="${2:-/srv/platform/portfolio/current}"
temporary="$(mktemp -d)"
trap 'rm -rf -- "$temporary"' EXIT

request() {
  curl --silent --show-error --max-time 15 "$@"
}

[[ "$(request --fail "${base_url}/healthz")" == "ok" ]]
[[ "$(request --output /dev/null --write-out '%{http_code}' "${base_url}/")" == "200" ]]

for resource in rss.xml sitemap.xml robots.txt; do
  [[ "$(request --output /dev/null --write-out '%{http_code}' "${base_url}/${resource}")" == "200" ]]
done

request --output "$temporary/spa" "${base_url}/route-that-does-not-exist"
[[ "$(request --output /dev/null --write-out '%{http_code}' "${base_url}/route-that-does-not-exist")" == "404" ]]
cmp --silent "$temporary/spa" "$release_root/__spa-fallback.html"

request --output "$temporary/missing-asset" "${base_url}/missing-asset.0123456789abcdef.js"
[[ "$(request --output /dev/null --write-out '%{http_code}' "${base_url}/missing-asset.0123456789abcdef.js")" == "404" ]]
if cmp --silent "$temporary/missing-asset" "$release_root/__spa-fallback.html"; then
  printf '%s\n' 'missing asset incorrectly received the SPA fallback' >&2
  exit 1
fi

route_index="$(find -L "$release_root" -mindepth 2 -type f -name index.html -print -quit)"
if [[ -n "$route_index" ]]; then
  route="/${route_index#"$release_root"/}"
  route="${route%/index.html}/"
  [[ "$(request --output /dev/null --write-out '%{http_code}' "${base_url}${route}")" == "200" ]]
fi

data_file="$(find -L "$release_root" -type f -name '*.data' -print -quit)"
if [[ -n "$data_file" ]]; then
  data_path="/${data_file#"$release_root"/}"
  content_type="$(request --head "$base_url$data_path" | awk -F': ' 'tolower($1) == "content-type" {gsub(/\r/, "", $2); print $2; exit}')"
  [[ "$content_type" == text/x-script* ]]
fi

printf '%s\n' 'portfolio smoke checks passed'
