# Production Identity platform scaffold

The production Identity checkpoint is source-complete but default-disabled. It preserves the
single `t4g.medium` ARM64 host direction, existing network/EIP/30-GiB encrypted root volume,
IMDSv2, SSM-only administration, existing portfolio service, and existing eight alarms. No new
Identity gate is enabled by committed values.

## Staged activation

Activation is deliberately ordered and must be separately reviewed:

1. Keep the reviewed Cognito core enabled through private task input.
2. Request the `auth.rahuly.in` ACM certificate in `us-east-1`; the external DNS owner creates and
   verifies the emitted records before the validation gate can be enabled.
3. Reference one existing Google credential secret with fields `client_id` and `client_secret`.
   Cognito is the sole consumer. The host policy rejects Google secret references.
4. Enable the Google IdP, validated custom domain, exact `https://rahuly.in` confidential client,
   and client-secret custody in that order.
5. Provision delivery foundations only after immutable GitHub owner/repository IDs and all runtime
   secret ARNs exist. Enable the runtime only after both application image indexes prove
   `linux/arm64` and every authentication endpoint/reference is supplied.
6. After exact external readback for `identity.rahuly.in`, run the fixed Identity TLS document.
   Run configure, TLS issuance, migrate/deploy, and scheduled verify in that order.

The authentication endpoint is `https://auth.rahuly.in` and goes directly to Cognito. The BFF is
same-origin at `https://rahuly.in`, with exact callback `/auth/callback` and signed-out target
`/auth/signed-out`. The Identity API endpoint is `https://identity.rahuly.in`; issuer and JWKS are
regional Cognito endpoints. The resource audience is `identity-service://api`, with only
`profile.read` and `profile.write` application scopes.

## Runtime and secrets

The gated Compose project uses digest-pinned PostgreSQL 18.4, Redis 8.2.1, and pgBackRest 2.59.1
support images with verified ARM64 manifests. The API and BFF accept only immutable repository
digests with independent ARM64 proof. API/BFF ports bind to loopback; PostgreSQL and Redis have no
published port; no container mounts the Docker socket.
The listener-free pgBackRest support sidecar alone uses host networking so the existing IMDSv2
hop-limit of one remains unchanged while the AWS SDK obtains the host role. PostgreSQL access is
only through the mounted administrative socket. Every service uses the host-role CloudWatch Logs
driver and an exact gated log group.

Secret values are never committed. The four host-readable secret schemas are names only:

- Cognito custody: `client_secret`.
- Database/internal TLS: `bootstrap_password`, `migrator_password`, `runtime_password`,
  `postgres_ca_crt`, `postgres_server_crt`, and `postgres_server_key`.
- Redis/internal TLS: `bff_password`, `redis_ca_crt`, `redis_server_crt`, and
  `redis_server_key`.
- Backup: `repository_cipher`.
- Google OAuth: `client_id` and `client_secret`; never host-readable.

Secrets are fetched only by exact ARN in the fixed configure document and captured without tracing.
The PostgreSQL bootstrap password is staged in a server-only root:999 directory and mounted as one
read-only file; the separate root:10001 client directory exposes only the bootstrap pgpass file to
the database container. Migrator and runtime passwords are not mounted into PostgreSQL.
Configuration holds the same exclusive lifecycle lock as deploy and rollback, stages every
download, executable, unit, helper, generated file, secret, TLS identity, owner, and mode, and
validates the complete candidate before an adjacent atomic rename can affect an active path. Its
five manual active-staging writes comprise two systemd units and three libexec helpers. Before the
first write, one manifest-driven path derives, creates, and verifies the complete and only parent
set: staged `etc/systemd/system` and `usr/local/libexec/platform`, each a real non-symlink directory
with exact root ownership, root group and mode 0755. Independent policy/executable derivation and
an isolated first-run, negative-failure, cleanup and exact-rerun fixture reject a missing, late,
undeclared, unused, symlink-accepted or metadata-weakened parent. It then verifies the canonical
units without changing their staged or installed bytes. Configuration creates a
private verification directory below the configure work root, decodes the two canonical unit
payloads for byte equality, and writes verification-only copies. A fixed unit/directive mapping
rewrites only Docker `ExecStart` plus Identity `ExecStartPre`, `ExecStart`, and `ExecStop` command
tokens to their existing absolute staged executable paths. Exact four-replacement cardinality and
a reverse byte proof preserve every argument, dependency, directive, and other byte. Each staged
executable must remain a real non-symlink executable with exact metadata before unfiltered
`systemd-analyze --recursive-errors=yes verify` runs on the copies. Base-OS commands and dependency
units therefore resolve from the real host; no partial alternate root, live placeholder, bind
mount, or installed-unit rewrite is involved. Before failure cleanup, the verifier emits one fixed
stage/status envelope with the byte counts, line counts, and SHA-256 of its non-secret stdout and
stderr captures. It disables the inherited transaction error handler inside its subshell so that
the evidence is measured before removal, and propagates the real failure status. Other configure
stages emit fixed stage/status codes without capturing secret values or arbitrary command output.
The private copies and captures are removed for both success and failure. A source-derived,
zero-secret diagnostic compares both recursive modes using canonical units and synthetic commands;
its rendered shell is exercised locally through success and failure cleanup before host use.
Configuration retains the prior generation and exact global objects
until success, restores all of them on any
failure, and removes raw staging material. An identical rerun is a no-op without a service stop or
restart only when every managed parent is a real root-owned/root-group directory at its reviewed
mode and every active binary, helper, unit, and enablement link or file has its exact type,
root ownership, mode, and content; metadata drift is not silently repaired while the workload is
active. Directory checks remove only the declaration's leading octal zero before comparing with
`stat %a`; declarations `0755` and `0700` therefore match their exact `755` and `700` metadata.
Ownership, group, directory type and non-symlink requirements remain exact. A host-global binary or unit upgrade while Identity is active fails before any active
write. Secret files are root-owned, single-service-group-readable files selected by one atomic
generation symlink. PostgreSQL clients require TCP with
`sslmode=verify-full`. The BFF constructs a process-local public/private CA bundle in tmpfs and
requires server-authenticated `rediss://` with ACL user `portfolio_bff`, no client certificate,
and exact key namespace `reference-bff:production:portfolio:identity`.

PostgreSQL has a `NOLOGIN NOINHERIT` owner, a `LOGIN INHERIT` migrator, and a `LOGIN NOINHERIT`
runtime role; all three are non-superuser, non-createdb, non-createrole, non-replication, and
non-bypass-RLS. The sole reviewed membership is owner granted to migrator with admin false,
inherit true, and set true. Bootstrap creates missing reviewed state but fails closed on pre-existing
role, membership-option, third-party-edge, ownership, or grant drift; it removes PUBLIC
database/schema privileges and then audits the exact current-head table, sequence, and column
privilege inventory after the published migration. The runtime role owns nothing, belongs to no
role, and receives no destructive, DDL, ownership, or role-escalation permission. Migrations
must reach exact head `0001_initial_identity_schema` before activation. Redis is BFF-only session and
OAuth-transaction state, uses TTL-compatible eviction, and has persistence disabled. Redis loss
invalidates sessions and requires reauthentication; no recovery claim is made. Recovery design is
deferred to future task `PLATFORM-P4-REDIS-RECOVERY-DESIGN-001`.

## Backup, recovery, and objectives

pgBackRest continuously consumes the PostgreSQL WAL spool into the existing versioned/encrypted
backup bucket under `identity/production`, with encrypted repository material, an unchanged Sunday
full association and six stable single-weekday `MON` through `SAT` differential associations,
four-full/fourteen-differential retention, freshness metrics, and
an isolated restore rehearsal operation. Before each backup, the operation commits a non-secret
recovery marker in an access-denied control schema and binds that marker and timestamp to bounded,
mode-0600 backup metadata. An immediate restore must select the latest successful marker; a
time-target restore must select an eligible marker at or before the target or fail closed. Each
rehearsal starts a portless restored PostgreSQL, proves the exact migration head and the marker that
existed before its selected backup, rejects marker visibility to the application role, and removes
its container and private directory.
EBS/DLM remains crash-consistent host recovery only.

Deploy and rollback validate their target release before switching and constrain the release
verifier to a real root-owned, root-group release parent and release root at mode 0755. A retained
release contains exactly regular `compose.yml` (mode 0644) and `release.env` (mode 0600), both
root-owned/root-group, with no additional member. Once activation begins, any Nginx,
systemd, verifier, or health failure restores the exact prior links, environment, Nginx
configuration, and service state, restarts the prior release, and proves it healthy. The previous
link is promoted only after the candidate is healthy.

The design objectives are RPO no greater than 24 hours and RTO no greater than 4 hours. They are
objectives pending live activation and repeated restore evidence, not achieved guarantees.

## Known prerequisites

Separate reviewed tasks must supply external DNS readback, Google credentials, runtime secrets,
Identity application digests and ARM64 manifest proofs, authorization to run the fixed Identity
TLS operation, and approved apply/deployment windows. This checkpoint performs none of those
actions.
# Host prerequisites and recovery

Before configuration, publish and execute `deploy/ssm/prepare-identity-host.sh --prepare`
with the exact `config/runtime/identity-host-packages.json` on the existing host through SSM.
The helper shares the lifecycle lock and permits only the pinned, signed, missing AL2023
package closure from release `2023.12.20260817`. It verifies the pre-existing RPM inventory,
rejects upgrades/removals/additional transaction members, and makes no package writes when
the exact closure is already installed. Git is the minimal `git-core` binary prerequisite;
the package solver selects the AL2023 legacy iptables provider, without installing a firewall
service or changing Docker's firewall management. Interrupted transactions require observed
RPM-state reconciliation before installing only the remaining missing members.

The host has SELinux enabled in its pre-existing Permissive mode. It records denials but does
not enforce mandatory access control. Preparation verifies and preserves that baseline;
Disabled or unexpected Enforcing/configuration drift is not normalized. No mode, boot,
label or policy transition occurs. DAC, capabilities, seccomp, no-new-privileges, TLS,
network/namespace isolation and IAM remain independent required controls.

Preparation reconciles only absent Docker/Identity units, exact dangling enablement links,
failed unit cache and a proved inactive Docker socket. Docker data and healthy nginx remain
untouched. It must complete before an SSM document update can automatically configure the host.
Configuration runs a read-only prerequisite check before fetching any runtime secret.

Configuration restoration stops newly started components before restoring files, distinguishes
prior unit absence from disabled/inactive and healthy states, and verifies the resulting state.
Fixed per-step status/count/hash evidence preserves the original failure independently of
restoration and cleanup. Transient staging is cleaned on failure; protected rollback copies
are retained when restoration is unproved. A subsequent configuration rejects nonempty staging
instead of deleting unresolved recovery evidence. Document compression preserves the complete
rendered script, verifies its SHA-256 before execution, and cleans its private decoder directory
on both success and failure.
