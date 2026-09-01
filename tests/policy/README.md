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

The sole Google identity-provider resource explicitly manages an empty
`idp_identifiers` collection and keeps exactly three caller-controlled
`provider_details` entries: scopes, client ID, and client secret. AWS provider
6.60.0 retains six additional Google Describe-response URL/method entries in
that map, so the lifecycle ignores only those six indexed response elements.
The complete map, caller-controlled entries, attribute mapping, identifiers,
provider identity, and pool binding remain managed, and `prevent_destroy`
remains mandatory. Both Cognito policy gates enforce this narrow normalization
boundary and reject broad or additional lifecycle ignores.

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
exact grammar, cardinality, and uniqueness validation must also pass. The exact
singleton comparison is deliberately type-stable: the typed `list(string)`
input must equal `tolist([format("https://%s", var.base_domain)])`; restoring a
tuple-literal comparison, removing the prerequisite, or weakening it is
forbidden. The child
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

State Manager scheduling is constrained to forms accepted by the service: six
stable single-weekday differential-backup associations keyed `MON` through
`SAT`, the unchanged Sunday full backup, and the exact every-30-minutes cron
for verification. All scheduled associations remain apply-only. Ranges, lists,
rate-plus-apply-only, immediate verification, missing or duplicate weekdays,
and additional association resources are rejected. The configure document must
create and verify the root-owned mode-0755 staged systemd parent before writing
either unit; missing, late, symlinked, or metadata-weakened parents fail the
executable contract.

Every payload embedded in the Identity configure document is produced with
OpenTofu `base64gzip`, decoded through the fixed base64/gzip pipeline into a
private metadata-checked temporary file, and published atomically only after a
successful decode. Permanent executable regression proof decompresses every
payload back to byte-identical canonical source. The document lifecycle guard
limits the base64 representation to 81,920 characters, which bounds the
rendered UTF-8 SSM document to 61,440 bytes. The stored verify document contains
no literal Docker Go-template opener; it constructs the exact running, health,
health-status, and restart-count templates from safe shell fragments at runtime
without `eval`, leaving zero undeclared SSM interpolation tokens.

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

Identity delivery trust uses GitHub's current ID-bearing repository prefix:
`repo:${var.github_owner}@${var.github_owner_id}/${var.github_repository}@${var.github_repository_id}:environment:${var.github_environment}`.
The production environment subject is a single exact value; the old name-only
subject is not an alternative. Independent policy and runtime gates consume the
operative trust blocks and cardinalities, ignoring comments, and retain exactly
one Allow statement, the sole federated principal/action, and four StringEquals
conditions for audience, subject, owner ID, and repository ID. No wildcard,
StringLike, extra principal/subject, or removed independent guard is accepted.
Backend-disabled OpenTofu evaluation uses the actual expression and typed module
inputs to prove the production subject and numeric-ID string conversion without
AWS access. Each complete disposable mutation fixture first passes its pristine
verifier (including the unchanged runtime-fixture input), then rejects exactly
its intended mutation. These tests do not request an OIDC token or prove actual
federation; live trust changes require separate review and apply authority.

The separate `PublishIdentityImages` statement permits exactly six ECR actions:
`BatchCheckLayerAvailability`, `BatchGetImage`, `CompleteLayerUpload`,
`InitiateLayerUpload`, `PutImage`, and `UploadLayerPart`, only on the existing
Identity API/BFF repository ARNs. `BatchGetImage` supports the manifest reads in
[AWS's required push permissions](https://docs.aws.amazon.com/AmazonECR/latest/userguide/image-push-iam.html).
The API-required `GetAuthorizationToken` wildcard remains in its separate
statement. Layer downloads, image/repository deletion, extra actions/statements,
wildcard or third/cross-repository grants, and changed policy/role bindings are
rejected. Host pull permissions remain a distinct, unchanged contract.
Both independent gates consume the entire operative publisher document and its
binding; host actions and comments cannot satisfy them. Backend-disabled HCL
evaluation proves the actual six-action list and two-repository comprehension
using local ARN fixtures, without AWS access. All 51 prior pristine mutation
controls remain, plus 25 publisher mutations that each first pass pristine and
then fail both independent gates with value-free diagnostics. These source and
policy-evaluation proofs do not perform registry login, federation, or image
operations and do not authorize a live policy change.
