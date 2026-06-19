# Testing

ClawBox tests are split by how much host machine state they require.

## CI-safe tests

Run:

```bash
bash tests/run-ci-tests.sh
```

This runner is intended to pass on a clean checkout. It includes deterministic
unit and mocked integration tests, and excludes checks that require a configured
local `.env`, real UTM VM, SSH session, launchd job, or installed workstation
state. It also excludes tests that require loopback socket binding, which some
restricted sandboxes block.

`tests/run-all-tests.sh` is also clean-checkout safe. It delegates to the
CI-safe runner so the default "all tests" command does not depend on local
workstation configuration.

## Release regression gate

Run:

```bash
bash tests/run-release-tests.sh
```

This is the focused release regression gate. It is also CI-safe and is included
by `run-ci-tests.sh`.

## Integration tests

Run:

```bash
bash tests/run-integration-tests.sh
```

These tests use mocks and do not require a configured ClawBox workstation, but
they may require local capabilities such as loopback socket binding.

## Workstation validation

Run:

```bash
bash tests/run-workstation-tests.sh
```

This validates the current machine's configured ClawBox environment. It requires
a real repository `.env` with completed setup values, so it is not clean-checkout
safe. Workstation tests are not required to pass on a clean checkout.

This is the runner that validates a configured local `.env`.

## Status inference probe

`./clawbox status` verifies VM-to-host LLaMA inference with a minimal direct
llama.cpp `/completion` request. It avoids OpenClaw sessions so status checks do
not depend on persistent gateway context.

## System tests

True end-to-end tests requiring UTM, SSH, launchd, and a real OpenClaw runtime
are not automated yet. `tests/run-system-tests.sh` documents this boundary.
