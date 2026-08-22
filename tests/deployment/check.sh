#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd -- "$repository_root"

for parameter in ArtifactBucket ArtifactKey ArtifactSHA256 ManifestKey ManifestSHA256 ReleaseID; do
  grep -Fq "$parameter" infra/modules/deployment/documents.tf
done
grep -Fq 'TargetReleaseID' infra/modules/deployment/documents.tf
! grep -Fq 'AWS-RunShellScript' infra/modules/deployment/iam.tf
! grep -Eq 's3:(Delete|PutBucket|PutLifecycle)' infra/modules/deployment/iam.tf
grep -Fq 'runtime configuration refuses a host with a TCP 22 listener' deploy/ssm/configure-runtime.sh.tftpl
grep -Fq 'runtime configuration refuses to invent a current link for an existing release set' deploy/ssm/configure-runtime.sh.tftpl
grep -Fq 'ord(character) < 32' deploy/ssm/deploy-portfolio.sh
grep -Fq 'ord(character) < 32' deploy/ssm/rollback-portfolio.sh

temporary="$(mktemp -d)"
trap 'rm -rf -- "$temporary"' EXIT
fixture="$temporary/client"
first="$temporary/first"
second="$temporary/second"
mkdir -p "$fixture/route"
printf '%s\n' '<!doctype html><title>fixture</title>' >"$fixture/index.html"
cp -- "$fixture/index.html" "$fixture/__spa-fallback.html"
cp -- "$fixture/index.html" "$fixture/route/index.html"
printf '%s\n' 'route-data' >"$fixture/route.data"
printf '%s\n' '<rss></rss>' >"$fixture/rss.xml"
printf '%s\n' '<urlset></urlset>' >"$fixture/sitemap.xml"
printf '%s\n' 'User-agent: *' >"$fixture/robots.txt"

node deploy/package-static.mjs \
  --input "$fixture" \
  --release-manifest deploy/releases/website-v1.0.0.json \
  --source-commit-time 1700000000 \
  --output-dir "$first" >/dev/null
node deploy/package-static.mjs \
  --input "$fixture" \
  --release-manifest deploy/releases/website-v1.0.0.json \
  --source-commit-time 1700000000 \
  --output-dir "$second" >/dev/null

artifact="website-v1.0.0-0bfde1c170e2b27ec92d98504b6fa25d66543bed.tar.gz"
manifest="website-v1.0.0-0bfde1c170e2b27ec92d98504b6fa25d66543bed.manifest.json"
cmp --silent "$first/$artifact" "$second/$artifact"
cmp --silent "$first/$manifest" "$second/$manifest"
node deploy/verify-artifact.mjs --artifact "$first/$artifact" --manifest "$first/$manifest" >/dev/null

printf '%s\n' 'deployment and artifact contract checks passed'
