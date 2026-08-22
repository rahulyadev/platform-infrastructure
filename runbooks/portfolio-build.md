# Immutable portfolio build

The approved input is `rahulyadev/website` tag `v1.0.0`, which must peel to
commit `0bfde1c170e2b27ec92d98504b6fa25d66543bed`. The build requires Node
`24.19.0`, npm `11.17.0`, `npm ci`, verification, E2E tests, and the production
build. No runtime environment variable is an input.

Run `deploy/build-portfolio.sh --output-dir <protected-directory>` outside this
repository. The script clones the public source into a temporary directory,
checks out the exact commit detached, proves a clean tree, and packages only
`build/client`. It creates a sorted file manifest with size/hash/classification,
normalizes archive ownership/modes/mtime and gzip metadata, verifies the archive
twice, and requires identical artifact and manifest hashes.

Retain the artifact, manifest, checksum files, and build evidence at mode
`0600`. CI additionally generates GitHub build provenance. Never upload a
partial or non-deterministic build.
