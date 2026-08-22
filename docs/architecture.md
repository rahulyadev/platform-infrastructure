# Platform architecture

## Current status

The state bucket, account budget, and production core are provisioned and
verified. Bootstrap and production states use encrypted, versioned S3 objects
and native S3 lock files. The current host is healthy, Systems Manager managed,
and converged with the reviewed core source.

Runtime resources remain source-only until a separately reviewed apply. Nginx,
TLS, CloudWatch Agent configuration, alarm subscriptions, snapshot automation,
GitHub OIDC deployment access, and portfolio deployment are not yet active.

## Production foundation

The application region is `ap-south-1`. The initial platform consists of one
custom VPC, one public subnet, one Internet Gateway, and one ARM64 Amazon Linux
2023 EC2 instance. The instance type is `t4g.small`, receives one Elastic IP,
and is administered through AWS Systems Manager. It has no EC2 key pair and no
public SSH ingress.

The public subnet disables automatic public IPv4 assignment, and the instance
is launched without requesting an automatically assigned public address. Its
sole stable public IPv4 address is managed as an Elastic IP with an explicit
association. This keeps subnet-level address assignment separate from the AWS
provider's computed public-association state.

The runtime design uses host Nginx to serve versioned, immutable static releases
through an atomic `current` symlink. Fixed Systems Manager documents configure
the runtime, deploy a content-addressed artifact, perform explicit rollback, and
enable TLS only after DNS validation. The documents do not accept arbitrary
shell commands. The artifact and backup buckets remain private.

CloudWatch Agent configuration records host metrics and safe Nginx logs at
standard resolution. Alarm notifications use SNS email subscriptions, which
remain pending until each recipient confirms after apply. DLM schedules seven
daily and three monthly instance snapshots; snapshots support host recovery but
do not replace application-aware backups.

GitHub deployment is designed to use an account-level OIDC provider and a role trusted only
for the immutable repository/environment subject. Its policy can upload under
the artifact bucket's `portfolio/` prefix and invoke only the fixed deploy and
rollback documents on the exact host. No static AWS key is part of the design.

Authoritative DNS remains with the existing external provider for the first
release. The domain is supplied as `base_domain`; the root derives the apex,
`www`, `auth`, and `identity` hosts. A later Cognito custom domain requires its
certificate in `us-east-1`, even though application resources remain in
`ap-south-1`.

## Availability and recovery

One instance is an intentional single failure domain. The static portfolio has
an RTO of 2 hours and RPO of 0 because an immutable source artifact must be
reproducible. A future stateful service has an RTO of 4 hours and RPO of 24
hours; no production database exists in the current root.

Production go-live requires the exact runtime plan and cost review, runtime
apply verification, SNS confirmation, protected GitHub environment controls,
artifact deployment and rollback proof, snapshot restore proof, and explicit
DNS/TLS cutover checks.

## Migration triggers

Revisit the single-host design when any of the following becomes material:

- Availability requirements exceed the documented RTO.
- Sustained load cannot be handled by vertical scaling.
- Deployments require independent application scaling or isolation.
- A production database or message workflow becomes necessary.
- Maintenance windows on a single host are unacceptable.
- Observed cost or operational effort favors managed services.

The migration path is incremental: establish observability and repeatable
artifacts, add load-balanced redundant compute when justified, and introduce
managed stateful services only with explicit backup, restore, migration, and
cost evidence. RabbitMQ is not permitted in production without a demonstrated
application workflow and operating model.

## Deliberate exclusions

The baseline has no NAT Gateway, IPv6, VPC endpoints, ALB, RDS, ECS/Fargate,
Kubernetes, multi-AZ resources, Cognito resources, production Redis, production
RabbitMQ, or Route 53 authoritative zone. Runtime source does not issue a
certificate, change DNS, upload an artifact, or deploy the portfolio.
