# Account cost bootstrap

This root defines one monthly cost budget with actual notifications at USD 25,
USD 35, and USD 40, plus forecast notifications at USD 35 and USD 40. It does
not define automatic shutdown or budget actions. The budget has been created
and verified with all five notifications.

The root declares one partial S3 backend with encryption and native lock files.
Its protected local state and ignored local-backend metadata remain unchanged
until migration. Supply the account ID and notification recipient outside Git
in an explicitly passed, ignored file such as `account.local.tfvars`, using
`terraform.tfvars.example` as a shape reference. Never commit the runtime file
or real recipient. The AWS provider rejects accounts other than
`expected_account_id`; the caller-identity preflight remains mandatory.

The root contains no IAM identities, policies, contacts, Organizations, or IAM
Identity Center resources. Migrate this root only after the state root is fully
verified in S3. The partial S3 block in `backend.tf` is already the sole active
backend; do not add another backend block. Use the existing protected local
state and metadata, create ignored `backend.hcl` from its example, and verify
the bucket, region, account allowlist, and exact key
`bootstrap/account/tofu.tfstate`. Reverify the protected backup and local-state
SHA-256, then run:

```bash
tofu init \
  -migrate-state \
  -input=false \
  -lockfile=readonly \
  -backend-config=backend.hcl
```

Do not combine `-migrate-state` with `-reconfigure`. Verify the remote state
object, versioning, state equality, native S3 lock-file behavior, and a
no-change plan before retiring reliance on the local copy.

See [the cost-controls runbook](../../../runbooks/cost-controls.md).
