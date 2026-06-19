#!/bin/bash
set -euo pipefail

# Default all-tests runner for clean-checkout-safe validation.
# Workstation-specific checks live in tests/run-workstation-tests.sh.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

cd "$ROOT_DIR"

bash tests/run-ci-tests.sh
