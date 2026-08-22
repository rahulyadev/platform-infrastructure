# Cost model and boundaries

## Review thresholds

- Warning: USD 25 per month.
- Critical: USD 35 per month.
- Hard review boundary: USD 40 per month.

The verified monthly USD 40 budget has actual notifications at USD 25, USD 35,
and USD 40, plus forecast notifications at USD 35 and USD 40. It has no budget
actions and does not enforce automatic shutdown.

## Price review

AWS pricing must be refreshed for the selected region immediately before every
apply. Documentation and estimates are not current-price guarantees. Record the
expected monthly delta, assumptions, taxes excluded, and price-retrieval date in
the plan review.

Major categories include EC2 compute, gp3 storage, public IPv4, S3 storage and
requests, snapshots, data transfer, CloudWatch custom metrics/alarms/logs, SNS
notifications, and DNS-provider charges. Runtime cost review must model normal
low-traffic logs and a conservative ten-times-log-volume case, seven daily and
three monthly snapshots, and retained immutable artifacts before apply.

## Cost constraints

The baseline deliberately excludes NAT Gateway, ALB, RDS, ECS/Fargate,
Kubernetes, and multi-AZ resources. Crossing the USD 40 boundary requires an
explicit architecture and funding review; budget notifications do not enforce
automatic shutdown.

Stopping an instance does not remove EBS, snapshot, Elastic IP/public IPv4, S3,
or logging costs. Cleanup reviews must identify unattached EBS volumes, stale
snapshots, unused public IPv4 allocations, incomplete multipart uploads, old
artifacts, and unused resources. Stop-cost procedures must preserve required
state and recovery evidence before deletion.
