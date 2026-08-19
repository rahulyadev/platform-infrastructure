# Remote-state bucket bootstrap

This root defines the private S3 bucket that can later store OpenTofu state. It
uses ignored local state as a one-time bootstrap exception because the bucket
does not yet exist.

The derived bucket name has this form:

```text
platform-infrastructure-<account-id>-<region>-state
```

It configures encryption, versioning, bucket-owner-enforced ownership, public
access blocking, a TLS-only policy, protected destruction, multipart cleanup,
and 365-day noncurrent-version retention by default.

Initialization and validation do not create the bucket. Creation requires a
separate saved-plan, cost-review, and apply workflow. The AWS provider rejects
accounts other than `expected_account_id`; the caller-identity preflight in the
runbook remains mandatory.

After creation, migrate state only in a separately reviewed source change. A
root may have only one active backend block: replace the local backend block in
`backend.tf` with the S3 block from `backend.s3.tf.example`; do not add a second
backend block. Create ignored `backend.hcl` from `backend.hcl.example`, then
replace its bucket, region, and `allowed_account_ids` placeholders with the
reviewed values. Back up the local state and record its SHA-256 before running:

```bash
tofu init \
  -migrate-state \
  -input=false \
  -lockfile=readonly \
  -backend-config=backend.hcl
```

Do not combine `-migrate-state` with `-reconfigure`, which would disregard
migration of the existing state. Confirm the remote state object and native S3
lock-file behavior before retiring reliance on the local copy. No DynamoDB lock
table is required.

See [the state bootstrap runbook](../../../runbooks/state-bootstrap.md).
