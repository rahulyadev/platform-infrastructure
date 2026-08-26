#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
set +x

readonly stamp="$(date -u +%Y%m%dT%H%M%SZ)"
readonly backup_type="${SSM_backupType:-diff}"
[[ "$backup_type" == full || "$backup_type" == diff ]]
docker compose --file /opt/platform/identity/current/compose.yml --project-name identity-production \
  exec --no-TTY pgbackrest pgbackrest --stanza=identity --type="$backup_type" backup
docker compose --file /opt/platform/identity/current/compose.yml --project-name identity-production \
  exec --no-TTY pgbackrest pgbackrest --stanza=identity check
docker compose --file /opt/platform/identity/current/compose.yml --project-name identity-production \
  exec --no-TTY pgbackrest pgbackrest --stanza=identity info --output=json >"/var/lib/platform/identity-backup-$stamp.json"
chmod 0600 "/var/lib/platform/identity-backup-$stamp.json"
mapfile -t expired_metadata < <(find /var/lib/platform -maxdepth 1 -type f -name 'identity-backup-*.json' -printf '%T@ %p\n' | sort -nr | awk 'NR > 14 {sub(/^[^ ]+ /, ""); print}')
for metadata_file in "${expired_metadata[@]}"; do
  [[ "$metadata_file" == /var/lib/platform/identity-backup-*.json ]]
  rm -f -- "$metadata_file"
done
docker compose --file /opt/platform/identity/current/compose.yml --project-name identity-production \
  exec --no-TTY pgbackrest touch /var/spool/pgbackrest/.last-backup-success
readonly metadata_token="$(curl --fail --silent --show-error --max-time 3 --request PUT \
  --header 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token)"
readonly instance_id="$(curl --fail --silent --show-error --max-time 3 \
  --header "X-aws-ec2-metadata-token: $metadata_token" http://169.254.169.254/latest/meta-data/instance-id)"
aws cloudwatch put-metric-data --region ap-south-1 --namespace PlatformInfrastructure/Production/Identity \
  --metric-data \
  "MetricName=IdentityBackupStale,Dimensions=[{Name=InstanceId,Value=$instance_id}],Value=0,Unit=Count" \
  "MetricName=IdentityWalArchiveStale,Dimensions=[{Name=InstanceId,Value=$instance_id}],Value=0,Unit=Count" >/dev/null
printf 'Identity differential backup and WAL archive verification passed.\n'
