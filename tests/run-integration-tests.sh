#!/bin/bash
set -euo pipefail

# Heavier mocked integration tests.
# These do not require a configured ClawBox workstation, but may require local
# capabilities such as loopback socket binding that restricted sandboxes block.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

cd "$ROOT_DIR"

bash tests/setup-test.sh
