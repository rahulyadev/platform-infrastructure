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
  and repository IDs, digest-only ARM64 images, migration-before-activation, retained prior release.
- Secrets: references only for Cognito custody, BFF runtime, database/TLS, Redis/TLS, backup
  encryption, and Google OAuth. Google credentials are Cognito/OpenTofu-only and not host-readable.
- Persistence: PostgreSQL is durable; pgBackRest WAL/PITR uses `identity/production` in the existing
  backup bucket. Redis is BFF-only disposable state with exact prefix `portfolio:identity:bff:`.
- Observability: existing eight alarms remain; gated Identity logs/alarms cover readiness, state
  reachability, restarts/failures, memory/disk, migrations, backup/WAL age, deployment, certificate.
- Recovery: fixed health/rollback/backup/restore operations; RPO <= 24 hours and RTO <= 4 hours are
  objectives pending repeated restore evidence. Redis loss requires reauthentication.
- Remaining prerequisites: reviewed apply windows, external DNS validation/readback, Google and
  runtime secret provisioning, application digest/ARM64 proof, and authorized fixed TLS issuance.
