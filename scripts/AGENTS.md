# Scripts Guide

## Purpose

Top-level executable entrypoints for ClawBox commands.

## Ownership

- `setup.sh` owns phase sequencing, top-level status handling, sourcing modules,
  and command-line setup entry behavior.
- `status.sh` owns host/VM health reporting for an already configured ClawBox
  environment.

## Local Contracts

- Keep `setup.sh` orchestration-focused. Move implementation detail to `lib/`
  modules rather than growing inline workflows.
- Preserve user-visible output, return codes, and global side effects during
  refactors.
- `status.sh` should avoid host-specific false negatives. VM launchd state for
  OpenClaw counts only when it proves a running service with PID and
  `openclaw gateway` arguments; process checks are fallback behavior.
- Status verifies VM-to-host inference with a minimal direct llama.cpp
  `/completion` probe, not a persistent OpenClaw session.

## Work Guidance

- Do not introduce production behavior changes while doing decomposition work.
- Keep setup phases explicit: environment bootstrap, requirements, host
  inference, VM onboarding, OpenClaw configuration, deployment, runtime setup.
- Avoid broad rewrites of setup/status flows unless tests and user request
  justify the blast radius.

## Verification

For syntax-sensitive script changes:

```bash
bash -n scripts/setup.sh
bash -n scripts/status.sh
```

For setup/status behavior changes, run the affected focused test plus:

```bash
bash tests/run-release-tests.sh
bash tests/run-ci-tests.sh
```

## Child DOX Index

No child AGENTS.md files under `scripts/`.
