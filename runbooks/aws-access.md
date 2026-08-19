# AWS access runbook

## Principles

- Never use root for routine work.
- Root MFA remains enabled and root access keys remain absent.
- Select an AWS profile explicitly for every command.
- Never copy credentials into Git, `.env` files, CI, logs, tickets, or handoffs.
- Stop when caller, account, or region differs from the reviewed target.

The existing administrator access key is a temporary bootstrap exception. It is
not the supported target model and must remain only until short-lived human and
automation access paths are configured and proven. Browser-authenticated local
access and role switching are planned, not yet configured.

## Preflight

1. Identify the intended environment, OpenTofu root, account ID, and region.
2. Select the named profile explicitly; do not rely on an ambient default.
3. Run `aws sts get-caller-identity --profile <profile>`.
4. Compare the caller ARN and account ID with the change record.
5. Confirm the configured and command-line region.
6. Stop if credentials are expired, unexpectedly privileged, or from another
   account. Do not reconfigure credentials during an infrastructure operation.

Do not print access-key IDs, secret keys, session tokens, cache content, or
credential source paths while troubleshooting.

## Target model

Human access uses browser-authenticated temporary credentials and explicit role
assumption. Discovery and provisioning permissions are separated. GitHub
deployment uses OIDC and short-lived credentials rather than stored AWS keys.
The target model requires separate implementation and verification before the
bootstrap key can be revoked.
