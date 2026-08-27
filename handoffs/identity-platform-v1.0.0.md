# Identity platform handoff v1.0.0

Status: default-disabled source checkpoint; no production activation.

- Names: production prefix `platform-infrastructure-production`; ECR suffixes `identity-api` and
  `identity-bff`; fixed SSM operations configure, Identity TLS, migrate/deploy, verify, rollback,
  backup, restore.
- Public endpoints: portfolio/BFF `https://rahuly.in`; Cognito `https://auth.rahuly.in`; Identity
  API `https://identity.rahuly.in`. Nginx never handles the Cognito hostname.
- Internal ports: Identity API `127.0.0.1:8081`; BFF `127.0.0.1:8082`; PostgreSQL/Redis private to
  the Compose state network. The listener-free backup sidecar alone uses host networking for the
  unchanged IMDSv2 hop-limit-one host-role credential path and PostgreSQL's mounted admin socket.
- OAuth: regional issuer/JWKS; audience `identity-service://api`; scopes `openid`,
  `identity-service://api/profile.read`, and `identity-service://api/profile.write`; callback
  `/auth/callback`; signed-out target `/auth/signed-out`.
- Deployment: `rahulyadev/identity-service`, protected `production` environment, immutable owner
  and repository IDs, digest-only ARM64 images, migration-before-activation, one shared lifecycle
  lock, staged failure-atomic configuration, and automatic prior-health restoration after every
  post-activation failure. The prior release is promoted only after candidate health succeeds.
- Secrets: the host reads exactly four references for Cognito client custody, database/TLS,
  Redis server-TLS/ACL, and backup encryption. Google credentials are Cognito/OpenTofu-only and
  not host-readable; no separate BFF cookie secret exists.
- Persistence: PostgreSQL is durable; exact role attributes, memberships, ownership, and
  current-head privileges are repaired and audited against drift. pgBackRest WAL/PITR uses
  `identity/production` in the existing backup bucket, and each selected backup is bound to a
  non-secret marker that demonstrably existed before the backup. Redis is BFF-only disposable state with exact namespace
  `reference-bff:production:portfolio:identity`.
- Observability: existing eight alarms remain; thirteen runtime-gated Identity alarms notify the
  existing SNS topic and treat a stopped 30-minute verifier as unhealthy.
- Recovery: fixed health/rollback/backup/restore operations; RPO <= 24 hours and RTO <= 4 hours are
  objectives pending repeated restore evidence. Redis loss requires reauthentication.
- Remaining prerequisites: reviewed apply windows, external DNS validation/readback, Google and
  runtime secret provisioning, application digest/ARM64 proof, and authorized fixed TLS issuance.
