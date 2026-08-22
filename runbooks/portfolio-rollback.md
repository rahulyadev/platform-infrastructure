# Portfolio rollback

Rollback is an explicit invocation of the fixed rollback document with one
validated `TargetReleaseID`. Record the active release, requested target,
manifest identity, instance, and command ID before execution.

The document recomputes every retained release file hash and size, atomically
activates the verified target, validates and reloads Nginx, and runs the same
local smoke checks. If activation fails, it restores the original release. The
rollback document never deletes releases or deployment state.

After success, confirm `current`, the deployment-state identity, HTTP root,
direct route navigation, required XML/text resources, SPA 404 behavior, and
ordinary missing-asset 404 behavior.
