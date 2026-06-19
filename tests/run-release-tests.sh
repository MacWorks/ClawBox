#!/bin/bash
set -euo pipefail

# Focused release regression gate. This runner is clean-checkout safe and uses
# mocked/unit coverage for behavior that would otherwise require host state.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

cd "$ROOT_DIR"

bash tests/release-regression-test.sh
bash tests/setup-coverage-test.sh
bash tests/llama-ownership-test.sh
bash tests/vm-detection-test.sh
bash tests/vm-state-test.sh
