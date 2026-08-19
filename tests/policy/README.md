# Policy checks

`scripts/check-policy.sh` evaluates active, non-ignored repository files without
reading `.terraform` working directories. It rejects forbidden service tokens,
public SSH and EC2 key-pair configuration, unsafe instance metadata or storage
settings, public S3 features, DynamoDB state locking, domain-coupled modules,
non-placeholder twelve-digit account IDs, non-placeholder email addresses,
common AWS access-key prefixes, credential-like assignments, private-key
headers, and unsafe file types.

It also requires exactly one blocking `allowed_account_ids` setting in each root
AWS provider, rejects warning-only `check "expected_account"` blocks, requires
an account allowlist placeholder in every `backend.hcl.example`, and rejects
tracked `terraform.tfvars` or `terraform.tfvars.json` runtime files.

Canonical `h1:` and `zh:` provider-checksum lines are excluded from the generic
twelve-digit scan because random checksum text is not an AWS account ID. Other
lock-file content remains subject to the scan.

The check reports file names rather than matching line content so a detected
credential-like value is not repeated in output. Policy fixtures can be added
later only if they cannot trigger production scans or contain secret-like test
values.
