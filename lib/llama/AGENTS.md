# LLaMA Lib Guide

## Purpose

Host `llama-server` installation, runtime configuration, and health detection
helpers.

## Ownership

- `llama-install.sh`: install/build selection and binary setup.
- `llama-runtime.sh`: launchd wrapper/env/plist paths and service setup.
- `llama-health.sh`: health, ownership, listener, and existing-instance
  classification.

## Local Contracts

- Preserve cross-user/external instance detection. A healthy existing API must
  be handled before requiring binary installation.
- Do not stop or replace a `llama-server` process unless ClawBox can determine
  it is safe and user-owned.
- Preserve `LLAMA_EXTERNAL` semantics for accepted external instances.
- Keep `/v1/models` readiness and direct completion status expectations aligned
  with `scripts/status.sh`.

## Work Guidance

- Keep install, runtime, and health logic separate.
- Avoid assumptions that process ownership, launchd ownership, and API health
  always agree.
- Keep user/system launchd mode behavior explicit.

## Verification

```bash
bash tests/llama-ownership-test.sh
bash tests/lib-tests.sh
bash tests/release-regression-test.sh
```

## Child DOX Index

No child AGENTS.md files under `lib/llama/`.
