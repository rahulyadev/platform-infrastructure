# Remote-state bucket bootstrap

This root defines the private S3 bucket used for OpenTofu remote state. The
bucket has been created and verified, but remains empty until the protected
local bootstrap states are migrated.

The root now declares one partial S3 backend with encryption and native S3 lock
files. Its existing protected local state and ignored local-backend metadata
remain unchanged so the next operation can perform the one-time migration.

The derived bucket name has this form:

```text
platform-infrastructure-<account-id>-<region>-state
```

It configures encryption, versioning, bucket-owner-enforced ownership, public
access blocking, a TLS-only policy, protected destruction, multipart cleanup,
and 365-day noncurrent-version retention by default.

Repository validation uses a temporary external `TF_DATA_DIR` and disables the
backend, so it neither reads nor changes authoritative backend metadata. The
AWS provider rejects accounts other than `expected_account_id`; the
caller-identity preflight in the runbook remains mandatory.

The creation and apply workflow remains useful if the bucket must ever be
recovered or rebuilt, but requires a separate saved plan, current cost review,
and exact apply authorization.

Migrate this root before the account root. A root may have only one active
backend block; the partial S3 block in `backend.tf` is already the sole active
backend. Use the existing protected local state and local-backend metadata, and
prepare ignored `backend.hcl` from `backend.hcl.example`. Verify its bucket,
region, `allowed_account_ids`, and exact key
`bootstrap/state/tofu.tfstate`. Reverify the protected backup and local-state
SHA-256 before running:

```bash
tofu init \
  -migrate-state \
  -input=false \
  -lockfile=readonly \
  -backend-config=backend.hcl
```

Do not combine `-migrate-state` with `-reconfigure`, which would disregard
migration of the existing state. Confirm the remote state object and native S3
lock-file behavior, state equality, versioning, and a no-change plan before
retiring reliance on the local copy. No DynamoDB lock table is required.

See [the state bootstrap runbook](../../../runbooks/state-bootstrap.md).
