# Snapshot and restore

The runtime plan defines one DLM EBS snapshot-management policy targeting the
production instance. It takes a daily snapshot at 03:00 UTC and retains seven,
plus a monthly snapshot on the first day at 04:00 UTC and retains three. It
includes the boot volume, copies source tags, and adds explicit backup-purpose
tags. There is no archive tier, cross-region copy, AMI lifecycle, or second
overlapping policy.

The DLM `NoReboot` parameter applies to custom AMI policies and is intentionally
unset for this EBS snapshot-management policy. These volume snapshots are
crash-consistent unless a separately designed application-aware quiescing
mechanism is added. The later restore test is the required recovery proof.

After apply, verify the DLM role trusts only `dlm.amazonaws.com`, has only the
AWS-managed DLM service-role policy, and targets the exact production instance
tags. Verify scheduled snapshots include the encrypted root volume and age out
according to retention.

Restore proof must use a separately authorized temporary volume or instance:
create from a selected snapshot, attach only to the isolated restore target,
mount read-only first, verify expected filesystem/content, record timings, then
remove the temporary resources through a reviewed cleanup. Snapshots are host
recovery evidence, not a substitute for application-aware backups.
