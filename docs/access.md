# AWS access principles

Root is prohibited for routine work. Root MFA is enabled and root access keys
must remain absent.

Operators explicitly select an AWS profile and run
`aws sts get-caller-identity` before any plan or mutation. The returned caller,
account, and intended region must match the reviewed change context.

Credentials must never be copied into Git, environment files, CI variables,
logs, handoffs, or documentation. The existing administrator access key is a
temporary bootstrap exception, not the supported target access model. Browser
login and role switching are not yet described as configured capabilities.

GitHub deployment will use OpenID Connect and short-lived role credentials. It
will not store AWS access keys. See [the access runbook](../runbooks/aws-access.md)
for operational checks and stop conditions.
