#!/bin/bash
set -euo pipefail

# Local workstation validation.
# Requires a configured repository .env for the current ClawBox machine.
# This runner is intentionally excluded from clean-checkout CI.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

cd "$ROOT_DIR"

bash tests/env-setup-test.sh
