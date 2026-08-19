# Account cost bootstrap

This root defines one monthly cost budget with actual notifications at USD 25,
USD 35, and USD 40, plus forecast notifications at USD 35 and USD 40. It does
not define automatic shutdown or budget actions.

The root starts with an ignored local backend. Supply the eventual account ID
and notification recipient outside Git in an explicitly passed, ignored file
such as `account.local.tfvars`, using `terraform.tfvars.example` as a shape
reference. For example, a future reviewed command can pass
`-var-file=account.local.tfvars`; do not create or commit that runtime file as
part of the foundation. No budget exists until a separately reviewed saved plan
is applied. The AWS provider rejects accounts other than `expected_account_id`;
the caller-identity preflight in the runbook remains mandatory.

The root contains no IAM identities, policies, contacts, Organizations, or IAM
Identity Center resources. A later state migration can use the committed S3
backend examples after the remote state bucket exists. A root may have only one
active backend block: in a separately reviewed source change, replace the local
block in `backend.tf` with the S3 block from `backend.s3.tf.example`; do not add
a second block. Create ignored `backend.hcl` from its example and replace the
bucket, region, and `allowed_account_ids` placeholders. Back up the local state,
record its SHA-256, and then run:

```bash
tofu init \
  -migrate-state \
  -input=false \
  -lockfile=readonly \
  -backend-config=backend.hcl
```

Do not combine `-migrate-state` with `-reconfigure`. Verify the remote state
object and native S3 lock-file behavior before retiring reliance on the local
copy.

See [the cost-controls runbook](../../../runbooks/cost-controls.md).
