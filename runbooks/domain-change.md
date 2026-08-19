# Domain-change runbook

Domain changes are coordinated external operations, not incidental infrastructure
updates.

## Change surface

Review all of the following together:

- Certificates and validation records.
- Apex, `www`, `auth`, and `identity` DNS records.
- Cognito custom domain and its `us-east-1` certificate.
- Google redirect URI configuration.
- Application callback and logout allowlists.
- Nginx server names and TLS configuration.
- Cookie domains and security attributes.
- CORS, CSRF, trusted origins, and canonical origins.
- Canonical URLs, sitemap, and robots configuration.
- Search Console properties and verification.
- Old-domain redirects preserving path and query string.

## Procedure

1. Inventory the current authoritative records, TTLs, HTTP behavior, TLS state,
   application allowlists, and certificate dependencies.
2. Define desired records and obtain all owning-application contracts.
3. Validate certificates before directing traffic.
4. Stage application, Cognito, Google, Nginx, cookie, CORS, and CSRF changes.
5. Lower TTLs only through a reviewed change and allow the old TTL to elapse.
6. Apply DNS changes at the authoritative provider.
7. Observe resolution, TLS, redirects, callbacks, logout, cookies, canonical
   pages, sitemap, and robots behavior.
8. Maintain an observation period long enough to cover recursive caches and
   client behavior.
9. Preserve the previous records and application configuration for rollback.

Rollback restores the previous endpoints and records while preserving paths and
queries. Do not retire the old domain until observation and rollback evidence is
complete.
