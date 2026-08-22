# Policy checks

`scripts/check-policy.sh` evaluates active, non-ignored repository files without
reading `.terraform` working directories. It rejects forbidden service tokens,
public SSH and EC2 key-pair configuration, unsafe instance metadata or storage
settings, public S3 features, DynamoDB state locking, domain-coupled modules,
non-placeholder twelve-digit account IDs, non-placeholder email addresses,
common AWS access-key prefixes, credential-like assignments, private-key
headers, and unsafe file types.

It also requires exactly one blocking `allowed_account_ids` setting in each root
AWS provider and rejects warning-only `check "expected_account"` blocks. Every
active root must contain exactly one S3 backend with encryption and native lock
files enabled; active local backends and the obsolete bootstrap S3 examples are
rejected. Every `backend.hcl.example` must contain its exact state key, account
allowlist placeholder, encryption setting, and native-lock setting.

Validation policy requires one mode-`0700` temporary root outside the repository
and a distinct external `TF_DATA_DIR` for each OpenTofu root. Both initialization
and validation must use that root-specific directory, and an EXIT trap must
remove the temporary validation tree. References to deleted backend examples or
guidance that suggests adding another active backend block are rejected.

Tracked `terraform.tfvars` or `terraform.tfvars.json` runtime files remain
forbidden.

The public-IP ownership policy requires subnet-level automatic public IPv4
assignment to remain disabled. The host's sole public IPv4 address is managed
by exactly one `aws_eip` resource and one explicit `aws_eip_association` that
links the managed allocation to the managed instance. The
`aws_instance.associate_public_ip_address` argument must remain unset because
the provider computes it after EIP association; lifecycle ignore rules are not
an accepted workaround.

Canonical `h1:` and `zh:` provider-checksum lines are excluded from the generic
twelve-digit scan because random checksum text is not an AWS account ID. Other
lock-file content remains subject to the scan.

The check reports file names rather than matching line content so a detected
credential-like value is not repeated in output. Policy fixtures can be added
later only if they cannot trigger production scans or contain secret-like test
values.
