# Production core

This root defines the production foundation: two private versioned S3 buckets,
one custom VPC and public subnet, an Internet Gateway and route table, a
restrictive edge security group, one Systems Manager-managed ARM64 EC2 host,
an encrypted gp3 root volume, and one Elastic IP.

It also contains the reviewed Identity Cognito core behind
`enable_identity_cognito_core`. The gate defaults to `false` and is absent from
committed production values. When enabled through protected production input,
the module owns only one deletion-protected Essentials-tier User Pool and the
exact `identity-service://api` resource server with `profile.read` and
`profile.write` scopes.

A separate source-only confidential reference-BFF app-client scaffold is
behind `enable_identity_reference_bff_client`. Its committed gate defaults to
`false`, and its application-origin list defaults to empty. Enabling it requires
an explicit fail-closed root validation: the Cognito-core gate must also be
enabled, and the origin collection must contain one to four valid production
HTTPS DNS origins. The module derives only `/auth/callback` and
`/auth/signed-out` URLs from those origins and configures an
authorization-code-only, Google-only client with a generated secret, exact
Identity scopes, 15-minute access and ID tokens, 14-day rotating refresh
tokens, revocation, least-attribute access, and source-backed destroy
protection. No production origin or client secret is committed or exposed by
this root.

The public subnet disables automatic public IPv4 assignment. The instance
leaves the provider-computed `associate_public_ip_address` argument unset, and
its sole public IPv4 address is owned by the managed Elastic IP and explicit
association.

The backend is partial S3 configuration with encryption and native S3 lock
files. Its required key is `production/core/tofu.tfstate`. This root already has
its sole active S3 backend block; do not add another backend block. The verified
remote-state bucket exists, but the bootstrap states must be migrated and
proven before this root is initialized. Its ignored `backend.hcl` is created
from `backend.hcl.example` with reviewed bucket, region, account allowlist, and
state key. The AWS provider also rejects accounts other than
`expected_account_id`; the caller-identity preflight remains mandatory.

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

The reference-BFF client gate must remain disabled until its production origin,
Google IdP, and secret-custody wiring are separately reviewed. Managed-login
domain and certificate resources, DNS, identity-service onboarding, databases,
Redis, RabbitMQ, Route 53 authoritative DNS, load balancers, and orchestrators
remain outside this scaffold.
