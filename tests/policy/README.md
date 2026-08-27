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

`tests/policy/check-cognito-core.sh` is the narrow exception to the blanket
Cognito prohibition. Across every Terraform file in
`infra/modules/identity_cognito_core`, it requires exactly two resource blocks:
`aws_cognito_user_pool.this` and
`aws_cognito_resource_server.identity_api`. Across every Terraform file in
`infra/modules/identity_cognito_reference_bff_client`, it requires exactly one
resource block: `aws_cognito_user_pool_client.reference_bff`. Every other
resource and every data, child-module, or provider block in either module are
forbidden; the client module also forbids import, moved, check, and provisioner
blocks. Across all active repository Terraform files, the complete Cognito
resource inventory is those three blocks plus exactly one
`aws_cognito_identity_provider.google` and one
`aws_cognito_user_pool_domain.auth` in the exact authentication module.
Cognito data blocks remain forbidden. Cognito provider references may occur
only inside the exact core, client, and authentication module directories.

The repository must contain exactly one normalized local source reference to
each published Cognito core/client module, including equivalent relative path
spellings, and both may exist only in `infra/live/production/core/main.tf`. The
core instantiation must
retain its exact module name, default-false count gate, source, `name_prefix`
and canonical-tag inputs, conditional outputs, and committed-value non-enable
check. The core module contract also enforces the Essentials tier,
deletion/destroy guards, administrator-only creation and recovery,
case-sensitive usernames, mutable required email, defensive password policy,
canonical tags, and exact resource/scope identifiers.

The reference-BFF client instantiation must retain its separate default-false
gate, empty committed origin default, exact source, fail-closed core outputs,
canonical name prefix, validated origin input, and null-while-disabled
non-secret root outputs. An explicit root-variable validation enforces that the
client gate can be enabled only with Cognito core, Google federation, the direct
custom domain, and the one exact portfolio origin; the collection's separate
exact grammar, cardinality, and uniqueness validation must also pass. The child
contract requires a generated secret,
authorization-code-only OAuth, exact `openid` and Identity scope inputs,
Google-only provider support, no native/API authentication flow, exact callback
and signed-out derivation, explicit 15-minute access/ID and 14-day refresh
validity, enabled ten-second refresh rotation, revocation, user-existence-error
prevention, three-minute auth sessions, exact email read/write attributes, and
`prevent_destroy`. Only its child `client_secret` output is sensitive; the root
must never expose it. No application origin may be committed. Additional
providers/domains, Identity Pools, Lambda, users, credentials, analytics, M2M,
and every other deferred Cognito resource remain forbidden. The authentication
module's staged ACM request/validation and Google credential reference, and the
exact generated-client-secret custody module, are the sole narrow exceptions
for those non-Cognito resource families.

The production runtime root is subject to the same blocking provider and S3
backend rules. Its state key must be exactly `production/runtime/tofu.tfstate`,
and it may consume only the approved non-sensitive production-core outputs.

Runtime policy also requires:

- an immutable GitHub OIDC subject built from owner ID, repository ID, and the
  protected environment, with no wildcard or configured thumbprint;
- a deployment role with no artifact deletion, bucket mutation, arbitrary
  `AWS-RunShellScript`, or infrastructure permissions;
- official GitHub/AWS actions pinned to full commit SHAs, minimal workflow
  permissions, and `environment: production`;
- the exact immutable website tag/commit/toolchain release manifest;
- safe Nginx logging, MIME, cache, TLS, and SPA-versus-asset 404 contracts;
- an instance-targeted EBS snapshot-management policy that includes the boot
  volume, omits the AMI-only `no_reboot` parameter, and retains the reviewed
  daily/monthly schedules; both schedules copy source tags and add only their
  schedule-specific `BackupPurpose` tag, so common tags are never duplicated in
  `tags_to_add`; plus the complete runtime alarm set;
- no NAT Gateway, load balancer, Route 53, database, container-orchestration,
  Cognito outside the exact disabled core scaffold, public S3, SSH, stored AWS
  key, state, plan, backend runtime, local variable, environment, or private-key
  file.

The runtime, Nginx, and deployment test suites build a temporary synthetic
static site outside Git, package it twice, compare the byte-identical outputs,
and verify its manifest and archive safety contract.

The public-IP ownership policy requires subnet-level automatic public IPv4
assignment to remain disabled. The host's sole public IPv4 address is managed
by exactly one `aws_eip` resource and one explicit `aws_eip_association` that
links the managed allocation to the managed instance. The
`aws_instance.associate_public_ip_address` argument must remain unset because
the provider computes it after EIP association; lifecycle ignore rules are not
an accepted workaround.

Canonical `h1:` and `zh:` provider-checksum lines are excluded from the generic
twelve-digit scan because random checksum text is not an AWS account ID. The
versioned platform-foundation handoff is the sole public-metadata exception: it
must contain the expected non-secret AWS account ID and rejects every different
twelve-digit value. Other repository and lock-file content remains subject to
the generic scan.

The check reports file names rather than matching line content so a detected
credential-like value is not repeated in output. Policy fixtures can be added
later only if they cannot trigger production scans or contain secret-like test
values.

`tests/policy/check-production-identity.sh` is the narrow production Identity
extension. It allows only the staged Google IdP and direct Cognito custom domain
in the exact authentication module and keeps the repository-wide Cognito
inventory at the reviewed five blocks. It also enforces ordered default-false
gates, ACM/custody placement, two immutable ECR repositories, immutable GitHub
identity, least IAM and non-Google host secrets, digest-pinned ARM64 support
images, private hardened state services, exact same-origin Nginx routes, fixed
SSM/migration/backup/restore operations, and preservation of the existing eight
alarms. Failures are contract-oriented and never reproduce matching values.
