# Production runtime root

This root defines runtime configuration and deployment-control resources around
the already provisioned production core. It reads only the reviewed outputs of
the core state at `production/core/tofu.tfstate`; it does not manage the EC2
instance, Elastic IP, EBS volume, network, or core buckets.

The partial S3 backend requires an ignored mode-`0600` `backend.hcl` whose key
is exactly `production/runtime/tofu.tfstate`. Runtime account, alert recipient,
and numeric GitHub IDs belong in an ignored `runtime.local.tfvars`; the committed
`runtime.tfvars` contains only public configuration and exact package pins.

The root plans CloudWatch logs/metrics/alarms, SNS email subscriptions, fixed
SSM documents and associations, a DLM snapshot policy, and an immutable GitHub
OIDC deployment role. An apply is separately gated. Applying the associations
will configure packages and runtime services on the existing host, so the saved
plan and operational runbooks must be reviewed first.

```bash
tofu init \
  -reconfigure \
  -input=false \
  -lockfile=readonly \
  -backend-config=backend.hcl

tofu plan \
  -input=false \
  -var-file=runtime.tfvars \
  -var-file=runtime.local.tfvars
```

Do not apply until the plan is reviewed, the alert recipient is approved, and
the protected GitHub `production` environment is configured. DNS changes,
certificate issuance, artifact upload, and deployment remain separate explicit
operations.
