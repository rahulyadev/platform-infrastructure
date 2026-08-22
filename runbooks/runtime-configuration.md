# Runtime configuration

The runtime configuration is delivered by the fixed
`platform-infrastructure-production-configure-runtime` Systems Manager document
and one association targeting the exact production instance. It must not be run
before the reviewed runtime plan is applied.

## Verification

1. Verify AWS caller, account, region, clean source commit, runtime state key,
   and exact instance ID.
2. Confirm the association targets one instance and reports `Success`.
3. Verify installed RPM identities against `config/runtime/packages.json` and
   Certbot `5.7.0` inside a pinned Python 3.12 virtual environment at
   `/opt/platform/certbot-5.7.0`.
4. Verify Nginx configuration with `nginx -t`, the service active/enabled, and
   the Certbot renewal timer active/enabled.
5. Verify the bootstrap release and atomic `current` symlink exist only when no
   immutable release was previously active.
6. Confirm CloudWatch Agent installation/configuration associations succeed and
   expected metrics/log streams begin arriving.

The document performs no general operating-system upgrade, certificate
issuance, firewall change, or SSH enablement. On failure, do not rerun blindly;
record the failed step and prepare a reviewed source or configuration correction.
