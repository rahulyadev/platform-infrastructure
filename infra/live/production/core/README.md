# Production core

This root defines the planned production foundation: two private versioned S3
buckets, one custom VPC and public subnet, an Internet Gateway and route table,
a restrictive edge security group, one Systems Manager-managed ARM64 EC2 host,
an encrypted gp3 root volume, and one Elastic IP.

The backend is partial S3 configuration with encryption and native S3 lock
files. Its required key is `production/core/tofu.tfstate`. This root already has
its sole active S3 backend block; do not add another backend block. The remote
state bucket must exist before this root is initialized with ignored
`backend.hcl` created from `backend.hcl.example`. Replace the bucket, region,
and `allowed_account_ids` placeholders before initialization. The AWS provider
also rejects accounts other than `expected_account_id`; the caller-identity
preflight remains mandatory.

If an existing local-backed root is migrated to this S3 layout, make a
separately reviewed source change that replaces its local block in `backend.tf`
rather than adding a second block. Back up the local state, record its SHA-256,
and run:

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

The Amazon Linux 2023 ARM64 AMI is selected through the official public SSM
parameter `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64`.
Initialization and validation do not resolve the value; a future plan will.

`base_domain` derives the apex, `www`, `auth`, and `identity` outputs, while all
resource names remain domain-neutral. The committed production values do not
include an account ID or credentials.

No resource in this root has been created. Before production go-live, separate
work must complete state-bucket creation and migration, budget creation, saved
plan and cost review, monitoring and alarms, an EBS snapshot policy, Nginx and
TLS, artifact build and deployment, GitHub OIDC, DNS cutover, rollback and
restore proof, Cognito, and identity-service onboarding. Databases, Redis,
RabbitMQ, Route 53 authoritative DNS, load balancers, and orchestrators are not
part of this root.
