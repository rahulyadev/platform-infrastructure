# Retain external authoritative DNS for v1

Status: Active

## Context

The domain already uses GoDaddy authoritative nameservers. Migrating DNS while
introducing the first platform deployment would combine independent risks.

## Decision

Retain GoDaddy authoritative DNS for v1. OpenTofu does not create a Route 53
hosted zone or records in the current roots.

## Consequences

DNS changes remain a separately controlled external operation, and automated
AWS DNS management is deferred. Certificate and endpoint handoffs must provide
precise non-secret record values for manual review.

## Alternatives considered

- Route 53 migration: enables AWS-native record management but adds delegation,
  DNSSEC, rollback, and propagation work during initial deployment.
