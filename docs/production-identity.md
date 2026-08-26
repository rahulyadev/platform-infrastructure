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

Secrets are fetched only by exact ARN in the fixed configure document, captured without tracing,
validated together with duplicate-key rejection, and activated through one atomic generation
symlink as root-owned, single-service-group-readable files. PostgreSQL clients require TCP with
`sslmode=verify-full`. The BFF constructs a process-local public/private CA bundle in tmpfs and
requires server-authenticated `rediss://` with ACL user `portfolio_bff`, no client certificate,
and exact key namespace `reference-bff:production:portfolio:identity`.

PostgreSQL has distinct bootstrap, no-login owner, login `identity_service_migrator`, and login
`identity_service_app` roles. The published migration script applies exact table and column grants;
the runtime role receives no destructive, DDL, ownership, or role-escalation permission. Migrations
must reach exact head `0001_initial_identity_schema` before activation. Redis is BFF-only session and
OAuth-transaction state, uses TTL-compatible eviction, and has persistence disabled. Redis loss
invalidates sessions and requires reauthentication; no recovery claim is made. Recovery design is
deferred to future task `PLATFORM-P4-REDIS-RECOVERY-DESIGN-001`.

## Backup, recovery, and objectives

pgBackRest continuously consumes the PostgreSQL WAL spool into the existing versioned/encrypted
backup bucket under `identity/production`, with encrypted repository material, weekly full and
six-day differential schedules, four-full/fourteen-differential retention, freshness metrics, and
an isolated restore rehearsal operation. Each rehearsal starts a portless restored PostgreSQL,
checks the exact head and deterministic content, and removes its container and private directory.
EBS/DLM remains crash-consistent host recovery only.

The design objectives are RPO no greater than 24 hours and RTO no greater than 4 hours. They are
objectives pending live activation and repeated restore evidence, not achieved guarantees.

## Known prerequisites

Separate reviewed tasks must supply external DNS readback, Google credentials, runtime secrets,
Identity application digests and ARM64 manifest proofs, authorization to run the fixed Identity
TLS operation, and approved apply/deployment windows. This checkpoint performs none of those
actions.
