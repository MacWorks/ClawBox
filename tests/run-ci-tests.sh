#!/bin/bash
set -euo pipefail

# Clean-checkout-safe test runner for CI and pre-commit validation.
# Excludes workstation/system validation that depends on a configured .env,
# real UTM VMs, SSH, launchd state, loopback socket binding, or other
# host-specific machine state.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

cd "$ROOT_DIR"

bash tests/run-release-tests.sh
bash tests/lib-tests.sh
bash tests/output-normalization-test.sh
bash tests/output-spacing-test.sh
bash tests/generate-openclaw-config-test.sh
bash tests/model-command-test.sh
bash tests/embeddings-test.sh
bash tests/vm-provision-test.sh
bash tests/repo-hygiene-test.sh
bash tests/setup-startup-smoke-test.sh
