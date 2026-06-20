# Runtime

This document describes the repeatable runtime behavior driven by `./clawbox setup`.

## Runtime responsibilities

Normal runtime work is limited to:

- validating host prerequisites
- checking SSH connectivity to the VM
- detecting whether OpenClaw is installed and running
- generating a local OpenClaw config
- syncing the authoritative VM config when needed
- copying `vm-provision.sh` to the VM runtime path when needed
- optionally starting OpenClaw as a VM user launchd service according to current state and `OPENCLAW_AUTOSTART`

Runtime does not install Homebrew, Node, or OpenClaw.

## Config synchronization

The authoritative VM config is `~/.openclaw/openclaw.json`.

ClawBox compares configs semantically, not byte for byte.

That comparison deliberately ignores:

- JSON formatting differences
- key ordering differences
- `gateway.auth`
- `meta`

Those exclusions matter because OpenClaw mutates runtime-managed fields after startup. Without normalization, the same effective config would look different on every run.

When a meaningful difference remains, setup requires explicit confirmation
before replacing the whole VM config. That replacement can remove user-managed
settings and restart a running gateway.

## Runtime states

`./clawbox setup` distinguishes between three VM states:

- OpenClaw not installed
- OpenClaw installed but not running
- OpenClaw actively running

Detection is performed over SSH inside a login shell.

`already running` now requires a live `openclaw gateway` process.

An active `com.clawbox.openclaw` launchd service is still inspected as supporting runtime state, but launchctl-loaded state alone does not count as an active runtime.

Stale artifacts alone do not count. A leftover plist, dead prior session, stale PID-like state, or other non-running residue must not be reported as an active runtime.

## Restart behavior

When the config is replaced and `OPENCLAW_AUTOSTART=true`, `./clawbox setup` may restart OpenClaw as a VM user launchd service so the new config takes effect.

When the config is unchanged:

- no overwrite prompt appears
- no restart is triggered for formatting-only or runtime-managed differences
- OpenClaw may still be started when it is installed, stopped, and `OPENCLAW_AUTOSTART=true`

When `OPENCLAW_AUTOSTART=true`, setup installs or refreshes a per-user launchd plist for OpenClaw in the VM, checks whether the `gui/$uid` launchd service is already loaded, safely boots out stale loaded state when needed, bootstraps the service once, and waits for both `launchctl print` and a live `openclaw gateway` PID before reporting success.

That plist is generated on the host and uploaded to the VM before `launchctl` runs. Runtime management does not rely on nested heredocs or multiline shell generation embedded directly inside quoted SSH commands.

If `launchctl bootstrap` fails, setup now surfaces the exact bootstrap command and stops instead of reporting a successful OpenClaw start.

OpenClaw runtime logs are written under the VM runtime checkout at `VM_RUNTIME_PATH/logs/runtime/openclaw.out.log` and `VM_RUNTIME_PATH/logs/runtime/openclaw.err.log`.

The VM's noninteractive SSH environment may not include Homebrew or Node in
`PATH`. ClawBox still resolves an absolute `openclaw` binary path for launchd,
while completion guidance uses `zsh -lc` so the VM user's `.zprofile` supplies
the Homebrew and Node PATH entries. Use the displayed `zsh -lc "openclaw
--help"` command rather than bare `openclaw` in one-shot SSH commands.

## VM runtime path

`VM_RUNTIME_PATH` is a staging location used by the host setup flow. The authoritative runtime config still lives at `~/.openclaw/openclaw.json`.

## Related docs

- `docs/setup/host.md`
- `docs/setup/provisioning.md`
- `docs/contract/clawbox-contract.md`
