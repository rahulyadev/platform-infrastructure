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

The production runtime is provisioned and converged. Nginx serves the immutable
`website-v1.0.1` release at [https://rahuly.in](https://rahuly.in), Let's Encrypt
TLS is active for the apex and `www`, CloudWatch monitoring and eight alarms are
healthy, SNS is confirmed, and the DLM snapshot policy is enabled. Deployment
uses GitHub OIDC and fixed Systems Manager documents; GitHub stores no AWS access
keys. GoDaddy remains the authoritative DNS provider.

Release rollback and a snapshot-to-isolated-host, read-only filesystem restore
have both been exercised. See the versioned
[platform foundation handoff](handoffs/platform-foundation-v1.0.0.md) for the
verified production contract and known limitations.

## Architecture

The production foundation uses:

- OpenTofu with state stored in a private, encrypted, versioned S3 bucket and
  native S3 lock files after bootstrap.
- One custom VPC and one public subnet in the application region.
- One ARM64 Amazon Linux 2023 `t4g.small` instance with an Elastic IP.
- Systems Manager for administration, with no EC2 key pair or public SSH.
- Host Nginx at the edge, configured through fixed Systems Manager documents.
- Private versioned S3 buckets for immutable portfolio artifacts and backups.
- Versioned release directories and atomic activation for static content.
- GoDaddy as the external authoritative DNS provider.

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
  deployment, snapshot, and disabled Identity Cognito core modules.
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
All four roots use partial S3 backends with encryption and native lock files.
Concrete bucket, key, region, and account configuration stays in ignored
`backend.hcl` files. Bootstrap, core, and runtime states are remote, versioned,
verified, and independently converged.

## Safety model

- Operators explicitly select an AWS profile and verify caller, account,
  region, root, backend, and saved-plan identity before mutation.
- Applies consume an exact reviewed saved plan.
- Credentials and secret values never belong in Git, local environment files,
  CI logs, or documentation.
- Root is not used for routine work, and root access keys remain absent.
- GitHub deployment uses OIDC rather than stored AWS access keys.
- Production changes require cost and rollback review.

See the [state bootstrap](runbooks/state-bootstrap.md),
[plan and apply](runbooks/plan-and-apply.md),
[AWS access](runbooks/aws-access.md),
[cost controls](runbooks/cost-controls.md), and
[domain change](runbooks/domain-change.md) runbooks.

## Scope

This foundation supports one live static portfolio host, foundational
networking, private storage, Systems Manager access, cost controls, monitoring,
immutable deployment, rollback, TLS, and tested snapshot restoration. A
default-false source scaffold defines only the future Cognito User Pool and
Identity API resource server; it is not provisioned. Google OAuth, app clients,
Cognito domain/certificate wiring, identity routing, databases, Redis,
RabbitMQ, multi-AZ designs, load balancers, and container orchestration are not
provisioned.
