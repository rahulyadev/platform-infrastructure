# State bootstrap runbook

## Purpose

Maintain the verified remote-state bucket and migrate the two protected local
bootstrap states to S3. The bucket exists and is currently empty; the state and
account roots retain their original local-backend metadata for the one-time
migration.

## Preflight

Record and verify:

- caller ARN and AWS account ID,
- selected profile and region,
- `infra/bootstrap/state` as the root,
- partial S3 backend source, existing local-backend metadata, protected local
  state, and intended remote bucket and key,
- expected monthly cost delta,
- rollback and state-safety procedure.

Run caller identity checks before initialization or planning. Stop on any account
or region mismatch.

## Creation or recovery review

The initial bucket is already created and verified. If recovery or rebuild is
ever required, use a separate reviewed workflow:

1. Prove the intended bucket is absent and preserve all state evidence.
2. Refresh regional pricing and confirm the expected cost.
3. Initialize without migrating state.
4. Create and review a saved plan containing only the state-bucket controls.
5. Record its path, SHA-256, external effects, and rollback expectations.
6. Apply only that exact saved plan.

The bucket must have SSE-S3 default encryption, versioning, bucket-owner-enforced
ownership, complete public-access blocking, a TLS-only policy, protected
destruction, incomplete multipart cleanup, and retained noncurrent versions.
Native S3 lock files are used; there is no DynamoDB lock table.

## State migration

Migration is a separate reviewed change:

1. Prove no other operation is active.
2. Confirm each root has exactly one partial S3 backend with encryption and
   native lock files. Do not add another active backend block.
3. Reverify the existing local-backend metadata, protected local state, and
   protected backup without changing them.
4. Prepare ignored `backend.hcl` from `backend.hcl.example`, verifying the
   bucket, region, `allowed_account_ids`, encryption, native locking, and state
   key.
5. Migrate the state root first using `bootstrap/state/tofu.tfstate`.
6. Run from `infra/bootstrap/state`:

   ```bash
   tofu init \
     -migrate-state \
     -input=false \
     -lockfile=readonly \
     -backend-config=backend.hcl
   ```

7. Do not combine `-migrate-state` with `-reconfigure`; reconfiguration would
   disregard migration of the existing state.
8. Confirm the exact remote object, versioning, state equality, native lock-file
   behavior, and a no-change plan. Retain the protected local copy and backup.
9. Only after the state root passes, repeat the same procedure from
   `infra/bootstrap/account` using `bootstrap/account/tofu.tfstate`.
10. Retain both pre-migration backups through the observation period.

Production core later uses `production/core/tofu.tfstate` and must not be
initialized until both bootstrap migrations are proven.

## Stale locks

Treat a lock as active until the owning operation and operator are conclusively
identified. Do not force-unlock without proving no operation is running,
capturing the lock identifier, backing up state, and obtaining explicit review.
