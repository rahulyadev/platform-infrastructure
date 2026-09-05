#!/usr/bin/env bash
set -Eeuo pipefail
repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd -- "$repository_root"
bash -n deploy/ssm/prepare-identity-host.sh
python3 tests/runtime/test-identity-host-recovery.py
