# Host Nginx for the first release

Status: Active

## Context

The first host serves static content and may later reverse-proxy explicitly
contracted services. Operations should remain simple on the single instance.

## Decision

Run Nginx directly on the host for v1. Configuration and certificate automation
will be added only after separate review.

## Consequences

Host configuration becomes part of deployment and recovery. Immutable static
release directories and atomic activation limit rollback complexity, but the
Nginx package and configuration are not container-isolated.

## Alternatives considered

- Immutable Nginx container: stronger packaging isolation but additional image,
  runtime, volume, and lifecycle management for the initial host.
- Managed load balancer: excluded from the low-cost baseline.
