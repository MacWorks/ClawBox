# Host Artifacts Guide

## Purpose

Host-side support scripts and artifacts used by setup, launchd, firewall, and
OpenClaw config generation.

## Ownership

- `host/scripts/generate-openclaw-config.sh`: generates VM OpenClaw config from
  repository `.env`.
- `host/scripts/llama-wrapper.sh`: launchd wrapper for host `llama-server`.
- `host/scripts/start-utm-vm.sh`: host VM startup wrapper used by LaunchAgent.
- `host/firewall/`: host firewall support artifacts.

## Local Contracts

- Generated OpenClaw config must preserve custom provider names and gateway mode.
- Wrapper scripts must be noninteractive and launchd-safe.
- Do not assume interactive shell profile state unless the wrapper explicitly
  loads what it needs.

## Work Guidance

- Keep host scripts portable across the macOS shell environment used by launchd.
- Preserve explicit diagnostics in wrappers; login-time failures are often only
  visible through logs.

## Verification

```bash
bash tests/generate-openclaw-config-test.sh
bash tests/lib-tests.sh
bash tests/run-ci-tests.sh
```

## Child DOX Index

No child AGENTS.md files under `host/`.
