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

tls_script='deploy/ssm/enable-tls.sh.tftpl'
grep -Fq 'with open("/etc/resolv.conf", encoding="utf-8")' "$tls_script"
grep -Fq 'https://dns.google/dns-query' "$tls_script"
grep -Fq 'https://cloudflare-dns.com/dns-query' "$tls_script"
[[ "$(grep -Fc 'application/dns-message' "$tls_script")" -ge 2 ]]
grep -Fq 'for record_type in (1, 28):' "$tls_script"
grep -Fq 'observed_type == 5' "$tls_script"
grep -Fq 'max_cname_depth = 8' "$tls_script"
grep -Fq 'maximum_attempts = 6' "$tls_script"
grep -Fq 'retry_delay_seconds = 10' "$tls_script"
grep -Fq 'if ipv4 != {expected} or ipv6:' "$tls_script"
grep -Fq 'if attempt == maximum_attempts:' "$tls_script"
! grep -Fq 'nameserver_addresses' "$tls_script"
! grep -Fq 'authoritative_addresses' "$tls_script"
! grep -Fq 'authoritative_responses' "$tls_script"
grep -Fq -- '--resolve "$${base_domain}:80:127.0.0.1"' "$tls_script"
grep -Fq -- '--resolve "www.$${base_domain}:80:127.0.0.1"' "$tls_script"
staging_line="$(grep -nF '  --staging \' "$tls_script" | cut -d: -f1)"
production_line="$(grep -nF '"$certbot" certonly \' "$tls_script" | tail -n 1 | cut -d: -f1)"
tls_install_line="$(grep -nF 'install -o root -g root -m 0644 "$temporary_config" "$nginx_config"' "$tls_script" | cut -d: -f1)"
renewal_line="$(grep -nF '"$certbot" renew --dry-run' "$tls_script" | cut -d: -f1)"
[[ -n "$staging_line" && -n "$production_line" && -n "$tls_install_line" && -n "$renewal_line" ]]
((staging_line < production_line))
((production_line < tls_install_line))
((tls_install_line < renewal_line))

build_script='deploy/build-portfolio.sh'
npm_ci_line="$(grep -nF '  npm ci' "$build_script" | cut -d: -f1)"
playwright_executable_line="$(grep -nF '    [[ -x node_modules/.bin/playwright ]]' "$build_script" | cut -d: -f1)"
playwright_install_line="$(grep -nF '    node_modules/.bin/playwright install --with-deps chromium' "$build_script" | cut -d: -f1)"
e2e_line="$(grep -nF '  npm run test:e2e' "$build_script" | cut -d: -f1)"
grep -Fq 'install_playwright_browser=false' "$build_script"
grep -Fq -- '--install-playwright-browser)' "$build_script"
grep -Fq 'install_playwright_browser=true' "$build_script"
grep -Fq '  if [[ "$install_playwright_browser" == true ]]; then' "$build_script"
[[ -n "$npm_ci_line" && -n "$playwright_executable_line" && -n "$playwright_install_line" && -n "$e2e_line" ]]
((npm_ci_line < playwright_executable_line))
((playwright_executable_line < playwright_install_line))
((playwright_install_line < e2e_line))
grep -Fq -- '--install-playwright-browser \' .github/workflows/deploy-portfolio.yml
! grep -Eq 'test:e2e.*(\|\||true)|--pass-with-no-tests|--grep-invert' "$build_script" .github/workflows/deploy-portfolio.yml

release_definition='deploy/releases/website-v1.0.1.json'
historical_release_definition='deploy/releases/website-v1.0.0.json'
expected_artifact_sha='5515111352fadc204afe3a49f5330d1f3ea095a3ec3ba17641c284b2b22269a3'
expected_manifest_sha='ccfffefdc4a4327200caeab4222b2b1803e9768dbf3f1e002d0b25ff45d16d4e'
[[ -f "$historical_release_definition" ]]
[[ "$(sha256sum "$historical_release_definition" | awk '{print $1}')" == '7e0650949182892d5423586e51ea889ccc03016ab96b69d869d5b2949e57befe' ]]
jq -e \
  --arg artifact_sha "$expected_artifact_sha" \
  --arg manifest_sha "$expected_manifest_sha" '
    .schemaVersion == 1 and
    .release.id == "website-v1.0.1" and
    .release.sourceRepository == "https://github.com/rahulyadev/website" and
    .release.tag == "v1.0.1" and
    .release.commit == "72794e19609cad9ebb54c41f015b924d0ebe0c0c" and
    .toolchain.node == "24.19.0" and
    .toolchain.npm == "11.17.0" and
    .commands.install == "npm ci" and
    .commands.verify == "npm run verify" and
    .commands.e2e == "npm run test:e2e" and
    .commands.build == "npm run build" and
    .outputDirectory == "build/client" and
    .runtimeEnvironmentVariables == [] and
    .expectedArtifact.sha256 == $artifact_sha and
    .expectedArtifact.manifestSha256 == $manifest_sha
  ' "$release_definition" >/dev/null

workflow='.github/workflows/deploy-portfolio.yml'
hash_gate_line="$(grep -nF -- '- name: Verify exact reviewed artifact hashes' "$workflow" | cut -d: -f1)"
attestation_line="$(grep -nF -- '- name: Attest build provenance' "$workflow" | cut -d: -f1)"
credentials_line="$(grep -nF -- '- name: Obtain short-lived AWS credentials' "$workflow" | cut -d: -f1)"
[[ -n "$hash_gate_line" && -n "$attestation_line" && -n "$credentials_line" ]]
((hash_gate_line < attestation_line))
((hash_gate_line < credentials_line))
grep -Fq ".expectedArtifact.sha256" "$workflow"
grep -Fq ".expectedArtifact.manifestSha256" "$workflow"
grep -Fq '[[ "$GENERATED_ARTIFACT_SHA" == "$expected_artifact_sha" ]]' "$workflow"
grep -Fq '[[ "$GENERATED_MANIFEST_SHA" == "$expected_manifest_sha" ]]' "$workflow"

runtime_configurator='deploy/ssm/configure-runtime.sh.tftpl'
grep -Fq '"schemaVersion": 1' "$runtime_configurator"
grep -Fq '"release": {"id": "bootstrap"}' "$runtime_configurator"
grep -Fq 'existing bootstrap manifest semantics differ' "$runtime_configurator"
grep -Fq 'mv -T -- "$bootstrap_manifest_temporary" "$bootstrap_manifest"' "$runtime_configurator"
grep -Fq 'chown root:nginx "$bootstrap_manifest"' "$runtime_configurator"
grep -Fq 'chmod 0440 "$bootstrap_manifest"' "$runtime_configurator"
python3 - "$runtime_configurator" <<'PYTHON'
import re
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(r"bootstrap_files = \(\n(?P<entries>.*?)\n\)", source, re.DOTALL)
if match is None:
    raise SystemExit("bootstrap manifest file set is missing")
entries = re.findall(r'^\s+"([^"]+)",$', match.group("entries"), re.MULTILINE)
expected = [
    "index.html",
    "__spa-fallback.html",
    "rss.xml",
    "sitemap.xml",
    "robots.txt",
]
if entries != expected or ".platform-manifest.json" in entries:
    raise SystemExit("bootstrap manifest file set differs")
PYTHON

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
  --release-manifest deploy/releases/website-v1.0.1.json \
  --source-commit-time 1700000000 \
  --output-dir "$first" >/dev/null
node deploy/package-static.mjs \
  --input "$fixture" \
  --release-manifest deploy/releases/website-v1.0.1.json \
  --source-commit-time 1700000000 \
  --output-dir "$second" >/dev/null

artifact="website-v1.0.1-72794e19609cad9ebb54c41f015b924d0ebe0c0c.tar.gz"
manifest="website-v1.0.1-72794e19609cad9ebb54c41f015b924d0ebe0c0c.manifest.json"
cmp --silent "$first/$artifact" "$second/$artifact"
cmp --silent "$first/$manifest" "$second/$manifest"
jq -e 'has("expectedArtifact") | not' "$first/$manifest" >/dev/null
node deploy/verify-artifact.mjs --artifact "$first/$artifact" --manifest "$first/$manifest" >/dev/null

printf '%s\n' 'deployment and artifact contract checks passed'
