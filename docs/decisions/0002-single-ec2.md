# One EC2 instance for the first release

Status: Active

## Context

The initial static workload is small and has a documented two-hour recovery
target. Managed orchestration and multi-AZ compute add cost and complexity.

## Decision

Use one ARM64 EC2 instance as an intentional low-cost single point of failure.
Administer it through Systems Manager and retain immutable release artifacts.

## Consequences

Instance or Availability Zone failure causes downtime until recovery. Monitoring,
artifact reproducibility, rollback, and restore proof are production prerequisites.

## Alternatives considered

- Multi-AZ EC2 behind an ALB: better availability at higher recurring cost.
- ECS/Fargate or Kubernetes: more orchestration than the first release needs.
- Fully managed static hosting: not selected for the broader planned host role.
