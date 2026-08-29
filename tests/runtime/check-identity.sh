#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
set +x

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd -- "$repository_root"
temporary="$(mktemp -d)"
chmod 0700 "$temporary"
trap 'rm -rf -- "$temporary"' EXIT

PYTHONPYCACHEPREFIX="$temporary/pycache" python3 -m py_compile config/runtime/identity-launcher.py
python3 tests/runtime/verify-identity-contract.py .
bash tests/runtime/check-identity-mutations.sh

render_root="$temporary/render"
install -d -m 0700 "$render_root" "$temporary/tofu-data"
cat >"$render_root/main.tf" <<'HCL'
terraform {
  required_version = "= 1.12.5"
}

variable "repository_root" {
  type = string
}

locals {
  identity_image_contract = jsondecode(file("${var.repository_root}/config/runtime/identity-images.json"))
  identity_compose = templatefile("${var.repository_root}/config/runtime/identity-compose.yml.tftpl", {
    postgres_image   = local.identity_image_contract.postgres.image
    redis_image      = local.identity_image_contract.redis.image
    pgbackrest_image = local.identity_image_contract.pgbackrest.image
    aws_region       = "ap-south-1"
    name_prefix      = "platform-infrastructure-production"
  })
  identity_nginx = templatefile("${var.repository_root}/config/nginx/identity-runtime.conf.tftpl", {
    base_domain = "rahuly.in"
  })
  identity_pgbackrest = templatefile("${var.repository_root}/config/runtime/pgbackrest.conf.tftpl", {
    backup_bucket = "platform-infrastructure-production-backup"
    aws_region    = "ap-south-1"
  })
  payloads = {
    compose           = local.identity_compose
    nginx             = local.identity_nginx
    pgbackrest        = local.identity_pgbackrest
    systemd_unit      = file("${var.repository_root}/config/runtime/identity-stack.service")
    postgres_roles    = file("${var.repository_root}/config/runtime/postgres-roles.sql")
    postgres_hba      = file("${var.repository_root}/config/runtime/postgres-hba.conf")
    launcher          = file("${var.repository_root}/config/runtime/identity-launcher.py")
    verify_release = replace(
      replace(
        file("${var.repository_root}/deploy/ssm/verify-identity-release.sh"),
        "__IDENTITY_API_REPOSITORY_URL__",
        "registry.example/identity-api"
      ),
      "__IDENTITY_BFF_REPOSITORY_URL__",
      "registry.example/identity-bff"
    )
    health_verify      = file("${var.repository_root}/deploy/ssm/verify-identity.sh")
    pgbackrest_sidecar = file("${var.repository_root}/config/runtime/pgbackrest-sidecar.sh")
    docker_service     = file("${var.repository_root}/config/runtime/docker.service")
    pgbackrest_passwd  = file("${var.repository_root}/config/runtime/pgbackrest-passwd")
  }
  configure = templatefile("${var.repository_root}/deploy/ssm/configure-identity-runtime.sh.tftpl", {
    docker_version              = local.identity_image_contract.docker.version
    docker_archive_sha256       = local.identity_image_contract.docker.archive_sha256
    compose_version             = local.identity_image_contract.compose.version
    compose_binary_sha256       = local.identity_image_contract.compose.binary_sha256
    pgbackrest_version          = local.identity_image_contract.pgbackrest.version
    pgbackrest_tar_sha256       = local.identity_image_contract.pgbackrest.tar_sha256
    compose_b64gzip             = base64gzip(local.payloads.compose)
    nginx_b64gzip               = base64gzip(local.payloads.nginx)
    pgbackrest_b64gzip          = base64gzip(local.payloads.pgbackrest)
    systemd_unit_b64gzip        = base64gzip(local.payloads.systemd_unit)
    postgres_roles_b64gzip      = base64gzip(local.payloads.postgres_roles)
    postgres_hba_b64gzip        = base64gzip(local.payloads.postgres_hba)
    launcher_b64gzip            = base64gzip(local.payloads.launcher)
    verify_release_b64gzip      = base64gzip(local.payloads.verify_release)
    health_verify_b64gzip       = base64gzip(local.payloads.health_verify)
    pgbackrest_sidecar_b64gzip  = base64gzip(local.payloads.pgbackrest_sidecar)
    docker_service_b64gzip      = base64gzip(local.payloads.docker_service)
    pgbackrest_passwd_b64gzip   = base64gzip(local.payloads.pgbackrest_passwd)
    bff_client_secret_arn       = "arn:example:client"
    database_secret_arn         = "arn:example:database"
    redis_secret_arn            = "arn:example:redis"
    backup_secret_arn           = "arn:example:backup"
  })
  document = jsonencode({
    schemaVersion = "2.2"
    description   = "Reviewed fixed configure Identity production operation"
    parameters    = {}
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "identityConfigure"
      inputs = {
        timeoutSeconds = "3600"
        runCommand     = [local.configure]
      }
    }]
  })
  proof = jsonencode({
    document_base64 = base64encode(local.document)
    payloads = {
      for key, plain in local.payloads : key => {
        plain      = base64encode(plain)
        compressed = base64gzip(plain)
      }
    }
  })
}
HCL

TF_DATA_DIR="$temporary/tofu-data" tofu -chdir="$render_root" init -backend=false -input=false -no-color >/dev/null
TF_DATA_DIR="$temporary/tofu-data" TF_VAR_repository_root="$repository_root" \
  tofu -chdir="$render_root" console -no-color <<<'base64encode(local.proof)' >"$temporary/proof.console"
jq -r . "$temporary/proof.console" | base64 --decode >"$temporary/proof.json"
python3 - "$temporary/proof.json" "$temporary/rendered-configure.sh" <<'PY'
import base64
import gzip
import json
import pathlib
import sys

proof = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
document_encoded = proof["document_base64"]
document_bytes = base64.b64decode(document_encoded, validate=True)
if len(document_bytes) > 61_440 or len(document_encoded) > 81_920:
    raise SystemExit("Rendered Identity SSM document exceeded its fixed size bound.")
document_text = document_bytes.decode("utf-8")
document = json.loads(document_text)
command = document["mainSteps"][0]["inputs"]["runCommand"]
if len(command) != 1 or document["parameters"] != {}:
    raise SystemExit("Rendered Identity SSM document shape drifted.")
pathlib.Path(sys.argv[2]).write_text(command[0], encoding="utf-8")
for value in proof["payloads"].values():
    plain = base64.b64decode(value["plain"], validate=True)
    packed = base64.b64decode(value["compressed"], validate=True)
    if gzip.decompress(packed) != plain:
        raise SystemExit("Compressed Identity payload did not reproduce canonical bytes.")
PY
chmod 0700 "$temporary/rendered-configure.sh"
bash -n "$temporary/rendered-configure.sh"

payload_root="$temporary/compressed-payload"
install -d -m 0700 "$payload_root"
printf 'compressed fixture bytes\n' >"$temporary/payload.expected"
payload="$(gzip --no-name --stdout "$temporary/payload.expected" | base64 --wrap=0)"
PLATFORM_IDENTITY_COMPRESSED_PAYLOAD_TEST_ROOT="$payload_root" \
PLATFORM_IDENTITY_COMPRESSED_PAYLOAD="$payload" \
  bash "$temporary/rendered-configure.sh" --compressed-payload-fixture
cmp -s "$temporary/payload.expected" "$payload_root/result"
[[ "$(stat -c '%a:%u:%g' "$payload_root/result")" == "600:$(id -u):$(id -g)" ]]
rm -f -- "$payload_root/result"
if PLATFORM_IDENTITY_COMPRESSED_PAYLOAD_TEST_ROOT="$payload_root" \
  PLATFORM_IDENTITY_COMPRESSED_PAYLOAD='invalid-compressed-payload' \
  bash "$temporary/rendered-configure.sh" --compressed-payload-fixture >"$temporary/invalid-payload.out" 2>&1; then
  printf 'Identity compressed-payload fixture accepted invalid input.\n' >&2
  exit 1
fi
[[ -z "$(find "$payload_root" -mindepth 1 -maxdepth 1 -print -quit)" ]]

sed \
  -e 's#${postgres_image}#postgres@sha256:a02db8cac496f15b094798a38254f14d6e00741f709360e5e00bb6668ea31636#g' \
  -e 's#${redis_image}#redis@sha256:5fa2edb1e408fa8235e6db8fab01d1afaaae96c9403ba67b70feceb8661e8621#g' \
  -e 's#${pgbackrest_image}#woblerr/pgbackrest@sha256:c5bc798fdbee479fc23fd419221755f8f0a97756f3a830ec7cc0c6678067e846#g' \
  -e 's#${aws_region}#ap-south-1#g' \
  -e 's#${name_prefix}#platform-infrastructure-production#g' \
  -e 's/$${/${/g' config/runtime/identity-compose.yml.tftpl >"$temporary/compose.yml"
IDENTITY_API_IMAGE=registry.example/identity-api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
IDENTITY_BFF_IMAGE=registry.example/identity-bff@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
COGNITO_ISSUER=https://cognito-idp.ap-south-1.amazonaws.com/ap-south-1_Example123 \
COGNITO_JWKS_URL=https://cognito-idp.ap-south-1.amazonaws.com/ap-south-1_Example123/.well-known/jwks.json \
COGNITO_CLIENT_ID=aaaaaaaaaaaaaaaaaaaaaaaaaa \
docker compose --file "$temporary/compose.yml" config --quiet

! grep -Eq 'ports:.*(5432|6379)' config/runtime/identity-compose.yml.tftpl
! grep -Eq '/var/run/docker.sock|/run/docker.sock' config/runtime/identity-compose.yml.tftpl
[[ "$(grep -Fc 'driver: awslogs' config/runtime/identity-compose.yml.tftpl)" == 6 ]]
[[ "$(grep -Fc 'network_mode: host' config/runtime/identity-compose.yml.tftpl)" == 1 ]]
! grep -Eq '^pg1-(host|port)=' config/runtime/pgbackrest.conf.tftpl

bash tests/runtime/check-identity-fixtures.sh
printf 'Production Identity runtime and packed immutable-application checks passed.\n'
