# Monitoring and alerts

The runtime root creates four log groups: Nginx access (7 days), Nginx error
(30), deployment (90), and system (30). The CloudWatch Agent publishes
60-second memory, root-disk, inode, swap, and Nginx-process metrics with the
instance ID dimension. Access logs omit query strings, cookies, authorization,
request bodies, and raw requests.

Alarms cover EC2 status, sustained CPU, low CPU credits, charged surplus
credits, memory, root disk, root inodes, and missing Nginx. Alarm and recovery
notifications use one SNS topic. Each email endpoint remains ineffective until
its recipient confirms the AWS subscription message after apply.

After apply, verify agent associations, parameter identity, metric dimensions,
log retention, and alarm actions. Test alarms through controlled metric/alarm
test procedures that do not disrupt production. T4g unlimited mode requires
continued review of `CPUCreditBalance`, `CPUSurplusCreditBalance`, and
`CPUSurplusCreditsCharged`. Add external HTTPS health monitoring only after DNS
and TLS cutover.
