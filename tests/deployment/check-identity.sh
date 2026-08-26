#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd -- "$repository_root"
for script in deploy/ssm/*identity*.sh; do bash -n "$script"; done
bash -n deploy/ssm/configure-identity-runtime.sh.tftpl
grep -Fq 'set +x' deploy/ssm/configure-identity-runtime.sh.tftpl
grep -Fq 'aws secretsmanager get-secret-value' deploy/ssm/configure-identity-runtime.sh.tftpl
! grep -Eq -- '--secret-string|--value[[:space:]]+.*secret|set -x' deploy/ssm/*identity*.sh*
grep -Fq 'sha256sum --check --status' deploy/ssm/configure-identity-runtime.sh.tftpl
grep -Fq "readonly digest_pattern='^[a-z0-9.-]+(/[a-z0-9/_-]+)+@sha256:[0-9a-f]{64}$'" deploy/ssm/deploy-identity.sh
grep -Fq "docker image inspect --format '{{.Architecture}}'" deploy/ssm/deploy-identity.sh
grep -Fq 'run --rm migrator' deploy/ssm/deploy-identity.sh
grep -Fq 'migrator check' deploy/ssm/deploy-identity.sh
grep -Fq 'identity-health-verify' deploy/ssm/deploy-identity.sh deploy/ssm/rollback-identity.sh
grep -Fq 'previous' deploy/ssm/rollback-identity.sh
grep -Fq 'identity-restore-rehearsal' deploy/ssm/restore-identity.sh
grep -Fq 'identity.rahuly.in' deploy/ssm/enable-identity-tls.sh
grep -Fq -- '--staging' deploy/ssm/enable-identity-tls.sh
grep -Fq 'IdentityWalArchiveStale' deploy/ssm/verify-identity.sh
grep -Fq 'Dimensions=[{Name=InstanceId' deploy/ssm/verify-identity.sh deploy/ssm/backup-identity.sh deploy/ssm/deploy-identity.sh
! grep -Eq 'tofu apply|aws ssm send-command|ssh |scp ' deploy/ssm/*identity*.sh*
printf 'Identity deployment source checks passed.\n'
