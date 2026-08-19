# Repository and contract ownership

## Platform infrastructure

`platform-infrastructure` owns shared AWS infrastructure definitions, account
bootstrap definitions, operational runbooks, deployment safety requirements,
and non-secret environment handoffs. It does not invent application runtime
contracts.

## Application repositories

Each application repository owns its build, tests, artifact format, runtime
port, health behavior, environment-variable contract, database migrations, and
standalone local-development path. Infrastructure consumes those contracts only
after they are versioned and handed off explicitly.

## Identity service

`identity-service` owns identity APIs, scopes, issuer expectations, callback and
logout requirements, client contracts, token semantics, migrations, and health
endpoints. This repository may provision supporting infrastructure only after
those interfaces are supplied; it must not infer them.

## Design system

`design-system` owns tokens, components, assets, package publication, and UI
compatibility contracts. It does not own cloud deployment resources.

## Contract boundaries

Infrastructure changes must not invent application ports, callback URLs,
OAuth scopes, database migrations, environment variables, or health endpoints.
Unknown values remain explicit blockers or deferred inputs.

An optional shared local stack may eventually provide common PostgreSQL, Redis,
or opt-in RabbitMQ services. Application repositories must continue to support
standalone local development; contributors must not need multiple repositories
merely to run one application.
