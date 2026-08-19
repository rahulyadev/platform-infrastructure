# OpenTofu as the infrastructure language

Status: Active

## Context

The platform needs reviewable, declarative infrastructure with reusable modules,
provider dependency locking, and an accessible state model.

## Decision

Use OpenTofu for AWS infrastructure definitions and require the repository's
documented OpenTofu version in every root.

## Consequences

State and provider locks require careful bootstrap and review. Contributors use
HCL and local validation before any cloud plan.

## Alternatives considered

- Terraform: similar workflow, but OpenTofu is selected for this repository.
- AWS CDK: introduces application-language dependencies and synthesized output.
- CloudFormation: AWS-specific and less suitable for the selected module layout.
