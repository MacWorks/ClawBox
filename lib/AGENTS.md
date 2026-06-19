# Lib Guide

## Purpose

Shared Bash implementation modules for setup, status, deployment, runtime,
logging, prompts, SSH, launchd, and host/VM helpers.

## Ownership

- `setup-*.sh` files own focused setup workflows and should keep
  `scripts/setup.sh` small.
- `runtime.sh`, `config.sh`, `deploy.sh`, and `ssh.sh` own VM runtime
  interaction, config sync, deployment, and SSH helpers.
- `launchagent.sh` owns the host login LaunchAgent that starts UTM/VM on login.
- `llama.sh` sources host LLaMA helper modules in `lib/llama/`.
- `vm/` owns VM startup/readiness/repair helpers.

## Local Contracts

- Preserve existing function names during extraction unless renaming materially
  improves ownership.
- Preserve global variables intentionally used as Bash module state.
- Do not silently change `.env` semantics. Existing configured values should be
  preserved unless setup explicitly prompts or a test requires migration.
- Do not run VM provisioning remotely from the host. `vm-provision.sh` remains a
  VM-local/manual handoff.
- Avoid unbounded waits; retry loops must be bounded and user-facing.

## Work Guidance

- Prefer small cohesive modules over large orchestration blobs.
- Document non-obvious module dependencies at the top of new setup modules.
- Keep comments sparse and useful.
- When moving code, remove the old implementation from the caller to avoid
  duplicate ownership.

## Verification

Run focused tests for the touched module. Common choices:

```bash
bash tests/lib-tests.sh
bash tests/output-normalization-test.sh
bash tests/vm-state-test.sh
bash tests/llama-ownership-test.sh
```

Then run:

```bash
bash tests/run-ci-tests.sh
```

## Child DOX Index

- `vm/AGENTS.md`: VM runtime, startup, SSH readiness, and repair helpers.
- `llama/AGENTS.md`: host LLaMA install/runtime/health helpers.
