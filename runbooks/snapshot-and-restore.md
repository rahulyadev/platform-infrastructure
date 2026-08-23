# Snapshot and restore

The runtime defines one enabled DLM EBS snapshot-management policy targeting
the production instance. It takes a daily snapshot at 03:00 UTC and retains
seven, plus a monthly snapshot on the first day at 04:00 UTC and retains three.
It includes the boot volume, copies source tags, and adds explicit
backup-purpose tags. There is no archive tier, cross-region copy, AMI lifecycle,
or second overlapping policy.

The DLM `NoReboot` parameter applies to custom AMI policies and is intentionally
unset for this EBS snapshot-management policy. These volume snapshots are
crash-consistent unless a separately designed application-aware quiescing
mechanism is added.

After apply, verify the DLM role trusts only `dlm.amazonaws.com`, has only the
AWS-managed DLM service-role policy, and targets the exact production instance
tags. Verify scheduled snapshots include the encrypted root volume and age out
according to retention.

## Restore procedure

1. Select a completed snapshot containing the expected encrypted production
   root volume and record its policy tags, creation time, and source volume.
2. Create an isolated restore target in the source Availability Zone. Use no
   ingress, no key pair, IMDSv2, Systems Manager administration, and only the
   narrowly required outbound connectivity.
3. Create one encrypted volume from the snapshot and attach it only to the
   isolated restore target. Never attach a recovery-test volume to production.
4. Resolve the attached block device by its volume identity, identify the
   filesystem, and mount it read-only. Use filesystem-specific safeguards such
   as XFS `nouuid,norecovery` or ext4 `noload` as appropriate.
5. Verify operating-system identity, application release identity, manifest
   file count and hashes, configuration, and public-certificate identity. Check
   only private-key existence and protection; never read or copy the key.
6. Unmount, detach and delete the restored volume, terminate the isolated host,
   delete its security group, and delete a manual proof-only snapshot. Retain a
   selected DLM-managed snapshot under its policy.
7. Confirm no active temporary resource remains and reverify production health
   and OpenTofu convergence.

Snapshots are host recovery evidence, not a substitute for application-aware
backups.

## Verified behavior

On 2026-08-22 UTC, a crash-consistent production-root snapshot was restored to
an isolated ARM64 host. The volume was mounted read-only, all 72 files in the
`website-v1.0.1` manifest were rehashed successfully, and the restored public
certificate fingerprint matched production. All proof-only resources were then
removed.
