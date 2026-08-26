# Production Identity activation and recovery runbook

This runbook describes future reviewed operations; it authorizes no apply or deployment.

## Activation gates

1. Verify state versioning/head/lock, current Cognito inventory, exact external DNS readback, and
   the approved account/region/caller.
2. Review the certificate request plan. After the external DNS owner confirms the exact validation
   records, separately review certificate validation, Google federation, and Cognito domain plans.
3. Verify the confidential client keeps Google-only authorization code flow, exact portfolio
   callbacks, rotation, least attributes, and destruction protection before enabling custody.
4. Verify immutable GitHub IDs, ECR scope, SSM documents, host secret references, image digests,
   `linux/arm64` manifests, and service certificates before delivery/runtime gates.
5. Run the fixed configure document. After exact `identity.rahuly.in` DNS readback, run the fixed
   Identity TLS document and require its staging and production ACME checks to pass.
6. Run the fixed migrate/deploy document. Migration, initial full backup, and drift checks must
   pass before the symlink switches. Run the fixed health verifier after activation; its scheduled
   association must continue proving services, capacity, migration, backup/WAL, and certificates.

Never pass a secret value on a command line, log it, inspect it interactively, or use direct host
editing as the normal path.

## Backup and restore rehearsal

The fixed backup document schedules weekly full and daily differential pgBackRest backups and
checks WAL/archive health. Treat backup-age or WAL-age alarms as deployment blockers.

The restore document creates a new isolated rehearsal directory and restores either the latest
consistent point or an exact UTC recovery target. Start a disposable PostgreSQL verifier against
the restored copy, confirm the seeded record and exact migration head, record timing, then remove
the rehearsal directory. Never point a rehearsal at the live data volume.

The RPO <= 24 hours and RTO <= 4 hours values are objectives until repeated live-compatible
rehearsals demonstrate them.

## Rollback

The deploy document retains the previously healthy immutable release. The fixed rollback document
switches only to that retained release and immediately reruns health and migration-head checks.
Database downgrades and destructive migrations are forbidden; use PITR/forward repair under a new
review if schema compatibility prevents application rollback.

Redis is disposable. Its loss invalidates sessions and requires users to authenticate again.
There is no Redis recovery claim; `PLATFORM-P4-REDIS-RECOVERY-DESIGN-001` remains future work.
