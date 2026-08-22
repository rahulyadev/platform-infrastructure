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

GitHub deployment is designed to use OpenID Connect and short-lived role credentials. The
trust policy binds the exact immutable GitHub owner/repository IDs and the
protected `production` environment; wildcard subjects are prohibited. The role
can write immutable portfolio objects, invoke only the fixed deploy/rollback
documents on the production instance, and poll their status. It cannot apply
infrastructure, invoke arbitrary shell documents, delete artifacts, issue a
certificate, or modify DNS.

The GitHub environment must be protected and its non-secret role/account
variables configured before the workflow is run. See the
[AWS access](../runbooks/aws-access.md) and
[GitHub OIDC deployment](../runbooks/github-oidc-deployment.md) runbooks.
