# VM Artifacts Guide

## Purpose

VM-local provisioning script and generated runtime config boundary.

## Ownership

- `vm-provision.sh`: VM-local/manual provisioning for Homebrew, Node/OpenClaw,
  config placement, and optional gateway start.
- `runtime/`: generated OpenClaw config destination. Keep `.gitkeep` tracked,
  but do not commit generated `openclaw.json`.

## Local Contracts

- Provisioning is VM-local. The host setup flow may copy instructions/scripts to
  the VM, but must not silently run provisioning remotely.
- Keep provisioning idempotent where possible.
- Preserve handoff messaging back to host setup.
- Generated runtime config under `runtime/` is local state and should stay
  ignored.

## Work Guidance

- Be careful with shell profile edits such as `.zprofile`; tests expect
  deduplication.
- Do not require launchd or host setup state inside VM provisioning.

## Verification

```bash
bash tests/vm-provision-test.sh
bash tests/output-normalization-test.sh
```

## Child DOX Index

No child AGENTS.md files under `vm/`.
