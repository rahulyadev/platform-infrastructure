#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
set +x

readonly lifecycle_lock=/run/lock/platform-identity-lifecycle.lock
install -d -m 0755 /run/lock
exec 9>"$lifecycle_lock"
flock -w 30 9

readonly stamp="$(date -u +%Y%m%dT%H%M%SZ)"
readonly marker_created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
readonly marker="$(openssl rand -hex 16)"
readonly backup_type="${SSM_backupType:-diff}"
readonly compose_file=/opt/platform/identity/current/compose.yml
readonly metadata_root=/var/lib/platform/identity-recovery
readonly temporary="$(mktemp -d /var/lib/platform/identity-backup.XXXXXXXX)"
[[ "$backup_type" == full || "$backup_type" == diff ]]
chmod 0700 "$temporary"
trap 'rm -rf -- "$temporary"' EXIT
install -d -m 0700 "$metadata_root"
/usr/local/libexec/platform/identity-verify-release

docker compose --file "$compose_file" --project-name identity-production exec --no-TTY postgres \
  psql --username identity_bootstrap --dbname identity --no-psqlrc --set ON_ERROR_STOP=1 \
  --set marker="$marker" --set marker_created_at="$marker_created_at" <<'SQL'
CREATE SCHEMA IF NOT EXISTS platform_recovery AUTHORIZATION identity_bootstrap;
REVOKE ALL ON SCHEMA platform_recovery FROM PUBLIC, identity_service_owner, identity_service_migrator, identity_service_app;
CREATE TABLE IF NOT EXISTS platform_recovery.markers (
  marker text PRIMARY KEY CHECK (marker ~ '^[0-9a-f]{32}$'),
  created_at timestamptz NOT NULL
);
ALTER TABLE platform_recovery.markers OWNER TO identity_bootstrap;
REVOKE ALL ON TABLE platform_recovery.markers FROM PUBLIC, identity_service_owner, identity_service_migrator, identity_service_app;
INSERT INTO platform_recovery.markers(marker, created_at) VALUES (:'marker', :'marker_created_at'::timestamptz);
CHECKPOINT;
SQL

docker compose --file "$compose_file" --project-name identity-production \
  exec --no-TTY pgbackrest pgbackrest --stanza=identity --type="$backup_type" backup
docker compose --file "$compose_file" --project-name identity-production \
  exec --no-TTY pgbackrest pgbackrest --stanza=identity check
docker compose --file "$compose_file" --project-name identity-production \
  exec --no-TTY pgbackrest pgbackrest --stanza=identity info --output=json >"$temporary/info.json"
chmod 0600 "$temporary/info.json"

python3 - "$temporary/info.json" "$temporary/metadata.json" "$marker" "$marker_created_at" "$backup_type" <<'PY'
import datetime
import json
import pathlib
import re
import sys
source, destination, marker, created_at, expected_type = sys.argv[1:]
value = json.loads(pathlib.Path(source).read_text(encoding="utf-8"))
if not isinstance(value, list) or len(value) != 1 or value[0].get("name") != "identity":
    raise SystemExit(2)
backups = value[0].get("backup")
if not isinstance(backups, list) or not backups:
    raise SystemExit(2)
latest = backups[-1]
label = latest.get("label")
kind = latest.get("type")
timestamps = latest.get("timestamp")
if not isinstance(label, str) or not re.fullmatch(r"[0-9]{8}-[0-9]{6}F(?:_[0-9]{8}-[0-9]{6}[DIF])?", label):
    raise SystemExit(2)
if kind != expected_type or not isinstance(timestamps, dict):
    raise SystemExit(2)
start = timestamps.get("start")
stop = timestamps.get("stop")
if not isinstance(start, int) or not isinstance(stop, int) or start <= 0 or stop < start:
    raise SystemExit(2)
created = datetime.datetime.strptime(created_at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
if int(created.timestamp()) > start:
    raise SystemExit(2)
metadata = {
    "version": 1,
    "marker": marker,
    "marker_created_at": created_at,
    "backup_label": label,
    "backup_type": kind,
    "backup_started_at": datetime.datetime.fromtimestamp(start, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "backup_stopped_at": datetime.datetime.fromtimestamp(stop, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "schema_head": "0001_initial_identity_schema",
}
pathlib.Path(destination).write_text(json.dumps(metadata, sort_keys=True, separators=(",", ":")) + "\n", encoding="ascii")
PY
chmod 0600 "$temporary/metadata.json"
metadata_target="$metadata_root/identity-backup-$stamp.json"
metadata_next="$metadata_root/.identity-backup-$stamp.json.next"
install -m 0600 "$temporary/metadata.json" "$metadata_next"
mv -Tf -- "$metadata_next" "$metadata_target"

mapfile -t expired_metadata < <(find "$metadata_root" -maxdepth 1 -type f -name 'identity-backup-*.json' -printf '%T@ %p\n' | sort -nr | awk 'NR > 14 {sub(/^[^ ]+ /, ""); print}')
for metadata_file in "${expired_metadata[@]}"; do
  [[ "$metadata_file" == "$metadata_root"/identity-backup-*.json ]]
  rm -f -- "$metadata_file"
done
docker compose --file "$compose_file" --project-name identity-production \
  exec --no-TTY pgbackrest touch /var/spool/pgbackrest/.last-backup-success

readonly metadata_token="$(curl --fail --silent --show-error --max-time 3 --request PUT \
  --header 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token)"
readonly instance_id="$(curl --fail --silent --show-error --max-time 3 \
  --header "X-aws-ec2-metadata-token: $metadata_token" http://169.254.169.254/latest/meta-data/instance-id)"
aws cloudwatch put-metric-data --region ap-south-1 --namespace PlatformInfrastructure/Production/Identity \
  --metric-data \
  "MetricName=IdentityBackupStale,Dimensions=[{Name=InstanceId,Value=$instance_id}],Value=0,Unit=Count" \
  "MetricName=IdentityWalArchiveStale,Dimensions=[{Name=InstanceId,Value=$instance_id}],Value=0,Unit=Count" >/dev/null
printf 'Identity backup and pre-backup recovery-marker verification passed.\n'
