# Cost-controls runbook

## Notification model

The verified monthly USD 40 cost budget has actual-spend notifications at USD
25, USD 35, and USD 40, plus forecast notifications at USD 35 and USD 40. These
are notifications, not automatic shutdown actions. It has no budget actions or
Budget Reports; notification delivery remains subject to AWS billing-data
refresh and threshold evaluation.

## Before an apply

1. Refresh current regional prices from authoritative sources.
2. Record the existing monthly estimate and proposed delta.
3. Include compute, EBS, public IPv4, S3, requests, transfer, snapshots,
   monitoring, logs, and external-provider charges.
4. Stop at the USD 40 hard-review boundary unless a separate review authorizes
   the revised architecture and spend.

## Stop-cost controls

Stopping compute does not eliminate EBS, snapshots, Elastic IP/public IPv4, S3,
or log-retention costs. Before stopping or deleting anything, preserve required
state, artifacts, backups, and recovery evidence. Record which costs continue
while stopped.

Regular cleanup review covers unattached volumes, stale snapshots, unused public
IPv4 allocations, abandoned instances, old artifacts, incomplete multipart
uploads, excess log retention, and unused resources. Deletion remains a separate
reviewed operation with recovery and ownership evidence.
