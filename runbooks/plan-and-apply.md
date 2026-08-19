# Plan and apply runbook

Every mutation requires a recorded review containing:

```text
caller ARN
account ID
region
environment/root
state key/backend
selected plan path and SHA-256
exact resource targets
monthly cost delta
external effects
rollback
state backup/safety
```

## Procedure

1. Start from a clean reviewed commit and explicit AWS profile.
2. Verify caller identity, account ID, region, root, and backend.
3. Refresh provider-dependent pricing and document the monthly delta.
4. Back up state when the change or backend warrants it.
5. Initialize with the reviewed backend configuration.
6. Create one saved plan at a deliberate path.
7. Calculate and record its SHA-256.
8. Review resource targets, replacements, deletions, external effects, cost,
   rollback, and state safety.
9. Apply the exact saved plan file. Do not run an unsaved second plan at apply
   time.
10. Capture non-secret outputs, health evidence, actual external effects, and
    rollback status.

Stop if the plan changes an unreviewed resource, depends on an unknown contract,
exceeds cost boundaries, contains sensitive material, or cannot be rolled back
safely.
