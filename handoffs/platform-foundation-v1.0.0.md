# Platform foundation handoff v1.0.0

## 1. Handoff identity

- Version: `1.0.0`
- Platform repository: `rahulyadev/platform-infrastructure`
- Infrastructure source SHA used for the final live platform:
  `34462920d4544defcb31f0b0a586a0d98148469f`
- AWS account: `402906459349`
- Region: `ap-south-1`
- Base domain: `rahuly.in`

`rahuly.in` is configuration through `base_domain`; it is not platform
identity. Follow [the domain-change runbook](../runbooks/domain-change.md) for a
domain replacement.

## 2. Production networking and compute

- VPC: `vpc-09dd96b45aa3bb5f1`
- Public subnet: `subnet-06d036ee58b98c976`
- Availability Zone: `ap-south-1a`
- Internet Gateway: `igw-0c55fb772728be7d3`
- Edge security group: `sg-0d00cdc2f37b7131c`
- Default-deny default security group: `sg-06fc4b9109aac685e`
- EC2 instance: `i-053c1b42c02b37d98`
- Instance type: `t4g.small`
- AMI: `ami-066a2d1dff4d3bfa5` (Amazon Linux 2023)
- Architecture: `arm64`
- Root EBS volume: `vol-024eebad15c109be0`, encrypted `gp3`, 30 GiB,
  delete-on-termination
- Elastic IP: `3.6.22.95`
- Instance profile: `platform-infrastructure-production-host`

The single EC2 instance is an intentional low-cost single point of failure.
There is no public SSH or EC2 key pair. Systems Manager is the administrative
path.

## 3. Public endpoints, DNS, and TLS

- Production endpoint: [https://rahuly.in](https://rahuly.in)
- `www.rahuly.in` redirects permanently to the HTTPS apex while preserving the
  path and query.
- GoDaddy authoritative nameservers: `ns73.domaincontrol.com` and
  `ns74.domaincontrol.com`
- Apex A: `3.6.22.95`
- `www`: CNAME to `rahuly.in`
- `auth.rahuly.in`: not provisioned; authoritative result is NXDOMAIN
- `identity.rahuly.in`: not provisioned; authoritative result is NXDOMAIN

TLS is issued by Let's Encrypt. The active certificate covers `rahuly.in` and
`www.rahuly.in`, expires at `2026-11-20T22:26:07Z`, and has SHA-256 fingerprint
`6C:9B:4B:D8:8F:EB:8B:D0:05:31:18:D7:E3:74:24:39:CB:5E:8A:D8:27:C0:68:73:C3:65:69:7A:F8:27:8C:2A`.
`platform-certbot-renew.timer` is active and enabled. The initial HSTS policy is
`max-age=300` without `includeSubDomains`.

## 4. Portfolio deployment

- Source repository: `rahulyadev/website`
- Tag: `v1.0.1`
- Commit: `72794e19609cad9ebb54c41f015b924d0ebe0c0c`
- Release ID: `website-v1.0.1`
- Artifact SHA-256:
  `5515111352fadc204afe3a49f5330d1f3ea095a3ec3ba17641c284b2b22269a3`
- Manifest SHA-256:
  `ccfffefdc4a4327200caeab4222b2b1803e9768dbf3f1e002d0b25ff45d16d4e`
- Artifact bucket:
  `platform-infrastructure-402906459349-ap-south-1-artifacts`
- Artifact object:
  `portfolio/website-v1.0.1/5515111352fadc204afe3a49f5330d1f3ea095a3ec3ba17641c284b2b22269a3/website-v1.0.1-72794e19609cad9ebb54c41f015b924d0ebe0c0c.tar.gz`
- Artifact object version: `UfJzKdaIltQ1ziNrpjeDm.QQ2Txb6wok`
- Manifest object:
  `portfolio/website-v1.0.1/5515111352fadc204afe3a49f5330d1f3ea095a3ec3ba17641c284b2b22269a3/website-v1.0.1-72794e19609cad9ebb54c41f015b924d0ebe0c0c.manifest.json`
- Manifest object version: `UZSCOLBP_u7CH2sry.8kkk3Ck4ZcUFPW`

`website-v1.0.0` remains on the host as the retained rollback release. The
activation sequence `v1.0.1 -> v1.0.0 -> v1.0.1` has been verified.

## 5. GitHub deployment contract

- Workflow: `.github/workflows/deploy-portfolio.yml`
- Environment: `production`
- Deployment branch policy: `main` only
- Environment secrets: none
- Environment variable names: `AWS_ACCOUNT_ID`, `AWS_DEPLOY_ROLE_ARN`
- OIDC provider: `https://token.actions.githubusercontent.com`
- Deployment role:
  `arn:aws:iam::402906459349:role/platform-infrastructure-production-deployer`
- OIDC audience: `sts.amazonaws.com`
- Exact OIDC subject:
  `repo:rahulyadev@66272748/platform-infrastructure@1338529929:environment:production`

GitHub deployment uses short-lived OIDC credentials; no stored AWS access keys
are used.

## 6. Remote state

State bucket:
`platform-infrastructure-402906459349-ap-south-1-state`

State keys:

- `bootstrap/state/tofu.tfstate`
- `bootstrap/account/tofu.tfstate`
- `production/core/tofu.tfstate`
- `production/runtime/tofu.tfstate`

The bucket uses S3 versioning and AES256 encryption. Each root uses the native
S3 lockfile; there is no DynamoDB lock table. State contents are not part of
this handoff.

## 7. Monitoring

Custom namespace: `PlatformInfrastructure/Production`

Log groups and retention:

- `/platform-infrastructure/production/nginx/access`: 7 days
- `/platform-infrastructure/production/nginx/error`: 30 days
- `/platform-infrastructure/production/deployment`: 90 days
- `/platform-infrastructure/production/system`: 30 days

Alarms:

- `platform-infrastructure-production-status-check-failed`: EC2 status checks
- `platform-infrastructure-production-cpu-high`: sustained CPU utilization
- `platform-infrastructure-production-cpu-credit-low`: low CPU credit balance
- `platform-infrastructure-production-cpu-surplus-charged`: charged surplus CPU
  credits
- `platform-infrastructure-production-memory-high`: host memory utilization
- `platform-infrastructure-production-root-disk-high`: root disk utilization
- `platform-infrastructure-production-root-inode-high`: root inode utilization
- `platform-infrastructure-production-nginx-process-absent`: missing Nginx
  process

Alarm topic:
`arn:aws:sns:ap-south-1:402906459349:platform-infrastructure-production-alarms`.
Its single email subscription is confirmed. The `t4g.small` instance uses
unlimited CPU credits; continue monitoring `CPUCreditBalance`,
`CPUSurplusCreditBalance`, and `CPUSurplusCreditsCharged`.

Amazon Linux 2023 does not currently provide `/var/log/messages`, so the system
log group has no stream. Access, error, and deployment streams are active.

## 8. Backups and recovery

- DLM policy: `policy-01f4eb830a1c5e303`
- Daily schedule: 03:00 UTC, retain 7
- Monthly schedule: first day of the month at 04:00 UTC, retain 3
- Boot volume: included
- Copy source tags: enabled

The EBS policy produces crash-consistent snapshots; it is not an
application-quiesced backup. Immutable release rollback has passed. A real
snapshot was restored to a 30 GiB volume, attached to an isolated restore host,
mounted read-only, and verified against all 72 `website-v1.0.1` manifest files.
The restored public-certificate fingerprint matched production, private-key
contents were never read, and all temporary recovery resources were cleaned up.

Static portfolio recovery objectives are RTO 2 hours and RPO 0 because source,
versioned artifacts, manifests, and remote state are retained independently.
Future stateful-service objectives, only when such services exist, are RTO 4
hours and RPO 24 hours.

## 9. Systems Manager documents and runtime

Fixed documents and current live versions:

- `platform-infrastructure-production-configure-runtime`: version 5
- `platform-infrastructure-production-deploy-portfolio`: version 1
- `platform-infrastructure-production-rollback-portfolio`: version 1
- `platform-infrastructure-production-enable-tls`: version 4

Active associations, all targeting the production instance and reporting
`Success`:

- `platform-infrastructure-production-install-cloudwatch-agent`
- `platform-infrastructure-production-configure-cloudwatch-agent`
- `platform-infrastructure-production-configure-runtime` (document version 5)

Pinned runtime packages:

- `nginx-1:1.30.4-1.amzn2023.0.1.aarch64`
- `awscli-2-2.33.15-1.amzn2023.0.1.noarch`
- `python3.12-3.12.13-2.amzn2023.0.5.aarch64`
- `python3.12-libs-3.12.13-2.amzn2023.0.5.aarch64`
- `python3.12-pip-23.2.1-4.amzn2023.0.10.noarch`
- `python3.12-pip-wheel-23.2.1-4.amzn2023.0.10.noarch`
- `python3.12-setuptools-68.2.2-4.amzn2023.0.3.noarch`
- `python3.12-setuptools-wheel-68.2.2-4.amzn2023.0.3.noarch`
- `python3.12-wheel-1:0.45.1-1.amzn2023.0.1.noarch`
- CloudWatch Agent `1.300071.0b1720`
- Certbot `5.7.0`

## 10. Cost

- Expected recurring monthly estimate with current free-tier assumptions:
  approximately USD 17.35
- Gross expected estimate without free-tier assumptions: approximately USD
  20.52
- Conservative gross estimate: approximately USD 41.82

The existing monthly Budget has an actual-spend warning at USD 25, actual and
forecast critical notifications at USD 35, and an actual and forecast hard
review threshold at USD 40. The operating platform may exceed the historical
USD 40 review threshold under the already reviewed conservative scenario.

## 11. Security limitations

**High:** the bootstrap `codex-agent` IAM user still uses a long-lived
administrator credential. Do not expose its key ID or value. Prove a replacement
short-lived interactive role/session workflow first, then revoke the long-lived
bootstrap key in a separately authorized change.

The current platform also intentionally has a single EC2 point of failure, no
multi-AZ deployment, no external load balancer, no NAT Gateway, no managed
database, and no Kubernetes or ECS. These are current architecture constraints,
not claims that those designs are impossible.

## 12. Future service onboarding boundary

- Cognito production resources: **NOT PROVISIONED**
- Google OAuth provider: **NOT CONFIGURED**
- Cognito app clients: **NOT CREATED**
- Callback URLs: **NOT DEFINED**
- Logout URLs: **NOT DEFINED**
- OAuth scopes: **NOT DEFINED**
- `identity.rahuly.in` routing: **NOT PROVISIONED**
- Identity-service runtime: **NOT PROVISIONED**
- Production PostgreSQL: **NOT PROVISIONED**
- Production Redis: **NOT PROVISIONED**
- Production RabbitMQ: **NOT PROVISIONED**

No callback, scope, port, health-check, environment-variable, migration,
database, or Redis requirement may be inferred from this handoff. The next
project must provide a source-backed identity-service infrastructure contract.
This platform project will then consume that contract and add only the required
infrastructure.

## 13. Secret boundary

This static portfolio requires no application runtime secrets. Documentation
may name secret references, such as a future OAuth client-secret reference, but
must never contain values. Protected operational contact values remain outside
public documentation. Future Google OAuth and application secrets must be
represented only by secret references after a source-backed service contract
exists.

## 14. Verified limitations and deferred work

- The long-lived bootstrap administrator credential described above remains.
- The production architecture has a single-instance failure domain.
- There is no external synthetic HTTPS checker.
- The system log group has no source stream on the current AL2023 host because
  `/var/log/messages` is absent.
- The pinned GitHub deployment actions currently emit a Node.js 20 deprecation
  annotation while GitHub forces them to run on Node.js 24.
