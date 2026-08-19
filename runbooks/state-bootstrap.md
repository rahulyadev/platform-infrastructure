# State bootstrap runbook

## Purpose

Create the remote state bucket safely and later migrate local bootstrap state to
S3. The local backend is a one-time bootstrap exception because the remote
bucket does not yet exist.

## Preflight

Record and verify:

- caller ARN and AWS account ID,
- selected profile and region,
- `infra/bootstrap/state` as the root,
- local backend path and intended remote bucket,
- expected monthly cost delta,
- rollback and state-safety procedure.

Run caller identity checks before initialization or planning. Stop on any account
or region mismatch.

## Creation review

1. Refresh regional pricing and confirm the expected cost.
2. Initialize without migrating state.
3. Create a saved plan file.
4. Record the plan path and SHA-256, exact targets, external effects, and
   rollback expectations.
5. Review that the plan creates only the state bucket controls.
6. Apply the exact saved plan; never replace it with a second unsaved plan.

The bucket must have SSE-S3 default encryption, versioning, bucket-owner-enforced
ownership, complete public-access blocking, a TLS-only policy, protected
destruction, incomplete multipart cleanup, and retained noncurrent versions.
Native S3 lock files are used; there is no DynamoDB lock table.

## Later state migration

Migration is a separate reviewed change:

1. Prove no other operation is active.
2. Remember that a root may have only one active backend block. In a separately
   reviewed source change, replace the local backend block in `backend.tf` with
   the S3 block from `backend.s3.tf.example`; do not add a second active block.
3. Prepare ignored `backend.hcl` from `backend.hcl.example` without committing
   it.
4. Replace and verify the bucket, region, and `allowed_account_ids`
   placeholders, as well as the state key.
5. Back up the complete local state to protected storage and record its
   SHA-256.
6. Run:

   ```bash
   tofu init \
     -migrate-state \
     -input=false \
     -lockfile=readonly \
     -backend-config=backend.hcl
   ```

7. Do not combine `-migrate-state` with `-reconfigure`; reconfiguration would
   disregard migration of the existing state.
8. Confirm the remote state object and native S3 lock-file behavior before
   retiring reliance on the local copy.
9. Retain the pre-migration backup through the observation period.

The production core key is `production/core/tofu.tfstate`. Bootstrap state uses
its separately documented key.

## Stale locks

Treat a lock as active until the owning operation and operator are conclusively
identified. Do not force-unlock without proving no operation is running,
capturing the lock identifier, backing up state, and obtaining explicit review.
