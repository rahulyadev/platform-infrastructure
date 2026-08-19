# Versioned platform return handoff

Use a committed, versioned handoff for every environment return. Never include
credential or secret values.

## Template

```text
Handoff version:
Date:
Environment:

AWS account ID:
AWS regions:
OpenTofu root:
State backend and key:

Deployed repository:
Tag:
Commit:
Artifact SHA-256:

Resource IDs:
Endpoints:
DNS status:
TLS status:

Cognito issuer:
Cognito client identifiers:
Callbacks:
Logout URLs:

Secret references (no values):
Database contract:
Redis contract:

Health evidence:
Rollback evidence:
Backup and restore evidence:
Current monthly cost and date:

Limitations:
Blockers:
```

Omit inapplicable contracts explicitly rather than inventing values. Cognito,
database, and Redis fields are populated only after those systems exist and
their owning repositories provide the contracts.
