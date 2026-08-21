# Platform infrastructure

This repository owns the shared infrastructure definition, operational safety
controls, and platform runbooks for a small personal application platform. It
does not own application behavior, application-specific deployment contracts,
or design-system code.

## Deployment status

The protected remote-state bucket and the monthly USD 40 budget with five
notifications have been created and verified. Their OpenTofu states remain in
protected local files until the separately reviewed one-time migration; the
state bucket is empty until that migration completes.

Production core has not been planned or provisioned. No EC2 instance, VPC,
Elastic IP, artifact or backup bucket, Nginx or TLS configuration, DNS cutover,
monitoring, snapshot policy, GitHub OIDC integration, or portfolio deployment
exists yet.

## Architecture

The planned production foundation uses:

- OpenTofu with state stored in a private, encrypted, versioned S3 bucket and
  native S3 lock files after bootstrap.
- One custom VPC and one public subnet in the application region.
- One ARM64 Amazon Linux 2023 `t4g.small` instance with an Elastic IP.
- Systems Manager for administration, with no EC2 key pair or public SSH.
- Host Nginx at the edge in a later implementation phase.
- Private versioned S3 buckets for immutable portfolio artifacts and backups.
- Versioned release directories and atomic activation for static content.
- The existing external authoritative DNS provider for the first release.

This intentionally low-cost design has a single-instance failure domain. See
[the architecture document](docs/architecture.md) for recovery targets,
migration triggers, and production-readiness dependencies.

## Configurable domain model

The production root accepts `base_domain` as configuration and derives the
portfolio apex plus `www`, `auth`, and `identity` hosts. Generic modules and
resource names do not embed an environment's domain.

## Repository layout

- `infra/bootstrap/state`: partial-S3-backend root for the verified remote-state
  bucket; its protected local state awaits migration.
- `infra/bootstrap/account`: partial-S3-backend root for the verified monthly
  cost budget; its protected local state awaits migration.
- `infra/live/production/core`: partial-S3-backend production network, buckets,
  and host root.
- `infra/modules`: reusable bucket, budget, network, and host modules.
- `docs`: architecture, ownership, cost, access, decisions, and handoff format.
- `runbooks`: state, apply, access, cost, and domain-change procedures.
- `scripts`: local validation and policy checks.
- `local`: ownership boundary for a future optional shared local stack.

## Prerequisites

- OpenTofu 1.12.5
- Bash and standard Unix utilities
- Explicit, separately configured AWS access only for future reviewed plan or
  apply workflows

No package installation is performed by repository validation.

## Local validation

```bash
make fmt
make check
```

`make check` verifies formatting, initializes each root with its backend
disabled, validates configuration, checks shell syntax, and applies repository
policy rules. It does not run an OpenTofu plan or call AWS intentionally.

## OpenTofu roots

Each root has independent provider dependency locks and backend documentation.
All three roots declare one partial S3 backend with encryption and native lock
files. Concrete bucket, key, region, and account configuration stays in ignored
`backend.hcl` files. The state and account roots retain protected local state
and local backend metadata for a one-time migration, performed state first and
account second; production core must not be initialized before both migrations
are proven.

## Safety model

- Operators explicitly select an AWS profile and verify caller, account,
  region, root, backend, and saved-plan identity before mutation.
- Applies consume an exact reviewed saved plan.
- Credentials and secret values never belong in Git, local environment files,
  CI logs, or documentation.
- Root is not used for routine work, and root access keys remain absent.
- GitHub deployment will use OIDC rather than stored AWS access keys.
- Production changes require cost and rollback review.

See the [state bootstrap](runbooks/state-bootstrap.md),
[plan and apply](runbooks/plan-and-apply.md),
[AWS access](runbooks/aws-access.md),
[cost controls](runbooks/cost-controls.md), and
[domain change](runbooks/domain-change.md) runbooks.

## Scope

This foundation supports one static portfolio host, foundational networking,
private storage, Systems Manager access, and budget definitions. Nginx and TLS,
artifact publication, monitoring, snapshots, GitHub OIDC, DNS changes, Cognito,
identity-service onboarding, databases, Redis, RabbitMQ, multi-AZ designs, load
balancers, container orchestration, and a local Compose foundation are deferred.
