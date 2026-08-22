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

release_definition='deploy/releases/website-v1.0.0.json'
expected_artifact_sha='bd43b937c621752a94c67c7a1b6495fa837d7ffd43b2bb1a5534a7442a54673d'
expected_manifest_sha='cc73b3874f514f19557a2f235eb4123199d366cc7c7ed7442b84daa0bc3a0138'
jq -e \
  --arg artifact_sha "$expected_artifact_sha" \
  --arg manifest_sha "$expected_manifest_sha" '
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
jq -e 'has("expectedArtifact") | not' "$first/$manifest" >/dev/null
node deploy/verify-artifact.mjs --artifact "$first/$artifact" --manifest "$first/$manifest" >/dev/null

printf '%s\n' 'deployment and artifact contract checks passed'
