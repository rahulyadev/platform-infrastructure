#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
set +x

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd -- "$repository_root"
for script in deploy/ssm/*identity*.sh; do bash -n "$script"; done
bash -n deploy/ssm/configure-identity-runtime.sh.tftpl
python3 tests/runtime/verify-identity-contract.py . >/dev/null

grep -Fq 'set +x' deploy/ssm/configure-identity-runtime.sh.tftpl
grep -Fq 'aws secretsmanager get-secret-value' deploy/ssm/configure-identity-runtime.sh.tftpl
! grep -Eq -- '--secret-string|--value[[:space:]]+.*secret|set -x' deploy/ssm/*identity*.sh*
grep -Fq 'sha256sum --check --status' deploy/ssm/configure-identity-runtime.sh.tftpl
grep -Fq 'get-login-password --region ap-south-1 | docker login --username AWS --password-stdin' deploy/ssm/deploy-identity.sh
grep -Fq "docker image inspect --format '{{.Architecture}}/{{.Os}}'" deploy/ssm/deploy-identity.sh
[[ "$(grep -Fc 'run --rm migrator' deploy/ssm/deploy-identity.sh)" == 1 ]]
! grep -Fq 'migrator check' deploy/ssm/deploy-identity.sh
grep -Fq 'identity-health-verify' deploy/ssm/deploy-identity.sh deploy/ssm/rollback-identity.sh
grep -Fq 'live_schema=' deploy/ssm/rollback-identity.sh
grep -Fq 'mktemp -d /var/lib/platform/identity-restore-rehearsal.XXXXXXXX' deploy/ssm/restore-identity.sh
grep -Fq 'IdentityWalArchiveStale' deploy/ssm/verify-identity.sh
grep -Fq 'Dimensions=[{Name=InstanceId' deploy/ssm/verify-identity.sh deploy/ssm/backup-identity.sh deploy/ssm/deploy-identity.sh
! grep -Eq 'tofu apply|aws ssm send-command|ssh |scp ' deploy/ssm/*identity*.sh*
printf 'Production Identity deployment source checks passed.\n'
