# GitHub OIDC deployment

The deployment role trusts only the GitHub token audience `sts.amazonaws.com`
and the immutable owner-ID/repository-ID subject for the protected
`production` environment. Wildcard subjects and OIDC thumbprint configuration
are prohibited. No static AWS key belongs in GitHub.

Before enabling deployment, configure protection on the existing GitHub
`production` environment, require appropriate reviewers, restrict deployment
branches to reviewed `main`, and add only the non-secret role ARN and expected
account ID variables used by the workflow. This repository does not create or
modify that GitHub environment.

The role can list/write/read immutable artifact objects under `portfolio/`,
send only the fixed deploy or rollback document to the exact instance, poll the
command, and perform minimal target discovery. It cannot delete artifacts,
invoke `AWS-RunShellScript`, configure runtime/TLS, mutate infrastructure, issue
certificates, or change DNS. Review the trust and role policy after every source
or GitHub identity change.
