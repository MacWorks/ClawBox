# Tests Guide

## Purpose

Automated regression, unit, mocked integration, workstation, and future system
test runners for ClawBox.

## Ownership

- `run-ci-tests.sh`: clean-checkout-safe deterministic test runner.
- `run-release-tests.sh`: focused release regression gate.
- `run-all-tests.sh`: default clean-checkout-safe all-tests runner, delegated to
  the CI runner.
- `run-integration-tests.sh`: mocked tests that may require local capabilities
  such as loopback socket binding.
- `run-workstation-tests.sh`: configured local `.env` validation.
- `run-system-tests.sh`: placeholder for future true UTM/SSH/launchd E2E tests.

## Local Contracts

- CI-safe tests must not depend on local `.env`, real UTM VMs, real SSH access,
  real launchd state, or persistent machine state.
- Do not weaken assertions to make a local workstation pass.
- Keep machine-state checks behind workstation/system runners.
- Use temp directories and mocks for setup/status regression coverage whenever
  practical.

## Work Guidance

- Add focused regressions for every production bug fix.
- Prefer deterministic shell fixtures over real host state.
- If a suite requires a host capability such as loopback sockets, keep that
  requirement documented in the runner contract.

## Verification

For test architecture changes:

```bash
bash tests/run-ci-tests.sh
bash tests/run-release-tests.sh
bash tests/run-all-tests.sh
```

Run `bash tests/run-workstation-tests.sh` only when validating a configured
local `.env`.

## Child DOX Index

No child AGENTS.md files under `tests/`.
