# Platform architecture

## Current status

The architecture in this document is planned. No infrastructure described here
has been provisioned or production-verified.

## Production foundation

The application region is `ap-south-1`. The initial platform consists of one
custom VPC, one public subnet, one Internet Gateway, and one ARM64 Amazon Linux
2023 EC2 instance. The instance type is `t4g.small`, receives one Elastic IP,
and is administered through AWS Systems Manager. It has no EC2 key pair and no
public SSH ingress.

Host Nginx will terminate web traffic and serve immutable static portfolio
releases from versioned directories. Activation will use an atomic symlink so a
previous release remains available for rollback. Release archives are planned
for a private, encrypted, versioned S3 artifact bucket; a second private bucket
provides a foundation for backups. Neither deployment automation nor Nginx is
implemented in the current root.

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

Production go-live requires proof of monitoring, certificate automation,
artifact deployment, rollback, and restore procedures. It also requires saved
plan review, cost review, state migration, DNS/TLS verification, and an EBS
snapshot policy.

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
RabbitMQ, Route 53 authoritative zone, Nginx configuration, or certificate
automation.
