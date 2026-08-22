# Portfolio deployment

The deployment workflow is manual-only and uses the protected GitHub
`production` environment. It rebuilds the fixed release, verifies deterministic
hashes, attests provenance, obtains short-lived OIDC credentials, uploads the
artifact and manifest under content-addressed `portfolio/` keys, and submits the
fixed deployment document.

Record the artifact bucket/key, artifact SHA-256, manifest key/SHA-256, release
ID, instance ID, and Systems Manager command ID. The document rejects unsafe
members, verifies every manifest path/size/hash, installs a new immutable
release, atomically switches `current`, validates/reloads Nginx, and runs local
HTTP smoke tests. A failed activation restores the prior symlink and reloads it.

Successful retention preserves current, previous, and three additional recent
releases. Deployment does not change DNS or issue a certificate. Treat command
failure as a deployment failure; do not bypass verification or activate files
manually.
