# Platform infrastructure

This repository owns the shared infrastructure definition, operational safety
controls, and platform runbooks for a small personal application platform. It
does not own application behavior, application-specific deployment contracts,
or design-system code.

## Deployment status

The protected state and account-budget roots use encrypted, versioned S3 state
with native lock files. The production core is provisioned and converged: one
ARM64 Amazon Linux 2023 host, its managed Elastic IP, custom VPC/subnet, private
artifact and backup buckets, and Systems Manager access are live.

The production runtime source defines Nginx, fixed deployment documents,
CloudWatch monitoring, SNS notifications, EBS snapshot schedules, and a GitHub
OIDC deployment role. Those runtime resources remain unapplied. Nginx and TLS
are not active, the immutable portfolio artifact has not been uploaded or
deployed, and GoDaddy DNS has not been cut over.

## Architecture

The planned production foundation uses:

- OpenTofu with state stored in a private, encrypted, versioned S3 bucket and
  native S3 lock files after bootstrap.
- One custom VPC and one public subnet in the application region.
- One ARM64 Amazon Linux 2023 `t4g.small` instance with an Elastic IP.
- Systems Manager for administration, with no EC2 key pair or public SSH.
- Host Nginx at the edge, configured through a fixed Systems Manager document
  only after the runtime plan is separately approved and applied.
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

- `infra/bootstrap/state`: remote-state bucket root using its migrated,
  protected S3 state.
- `infra/bootstrap/account`: monthly cost-budget root using its migrated,
  protected S3 state.
- `infra/live/production/core`: partial-S3-backend production network, buckets,
  and host root.
- `infra/live/production/runtime`: isolated runtime, monitoring, snapshot, and
  deployment-control root that reads the core remote state.
- `infra/modules`: reusable bucket, budget, network, host, runtime monitoring,
  deployment, and snapshot modules.
- `config`: reviewed Nginx and CloudWatch Agent configuration.
- `deploy`: immutable release identity, deterministic artifact tooling, fixed
  Systems Manager scripts, and smoke tests.
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
All four roots declare one partial S3 backend with encryption and native lock
files. Concrete bucket, key, region, and account configuration stays in ignored
`backend.hcl` files. Bootstrap and core states have been migrated and verified;
the runtime state key is created only by a separately reviewed runtime apply.

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
private storage, Systems Manager access, cost controls, and a reviewed runtime
and immutable-deployment design. Runtime apply, SNS confirmation, GitHub
environment protection, artifact publication/deployment, TLS issuance, DNS
cutover, Cognito, databases, Redis, RabbitMQ, multi-AZ designs, load balancers,
and container orchestration remain separately gated.
