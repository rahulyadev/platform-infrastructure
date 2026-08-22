# Snapshot and restore

The runtime plan defines one DLM instance policy. It takes a no-reboot snapshot
daily at 03:00 UTC and retains seven, plus a monthly snapshot on the first day
at 04:00 UTC and retains three. It copies source tags and adds explicit backup
purpose tags. There is no archive tier, cross-region copy, AMI lifecycle, or
second overlapping policy.

After apply, verify the DLM role trusts only `dlm.amazonaws.com`, has only the
AWS-managed DLM service-role policy, and targets the exact production instance
tags. Verify scheduled snapshots include the encrypted root volume and age out
according to retention.

Restore proof must use a separately authorized temporary volume or instance:
create from a selected snapshot, attach only to the isolated restore target,
mount read-only first, verify expected filesystem/content, record timings, then
remove the temporary resources through a reviewed cleanup. Snapshots are host
recovery evidence, not a substitute for application-aware backups.
