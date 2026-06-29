# Runtime

This document describes the repeatable runtime behavior driven by `./clawbox setup`.

## Runtime responsibilities

Normal runtime work is limited to:

- validating host prerequisites
- checking SSH connectivity to the VM
- detecting whether OpenClaw is installed and running
- generating a local OpenClaw config for first-run bootstrap or explicit reset
- syncing only ClawBox-managed OpenClaw keys when an authoritative VM config already exists
- copying `vm-provision.sh` to the VM runtime path when needed
- optionally starting OpenClaw as a VM user launchd service according to current state and `OPENCLAW_AUTOSTART`

Runtime does not install Homebrew, Node, or OpenClaw.

## Config synchronization

The authoritative VM config is `~/.openclaw/openclaw.json`.

For existing configs, ClawBox no longer compares or replaces the whole file.
It reads only ClawBox-managed keys with `openclaw config get` and updates drift
with `openclaw config set`.

Legacy semantic comparison helpers compare configs semantically, not byte for
byte.

That comparison deliberately ignores:

- JSON formatting differences
- key ordering differences
- `gateway.auth`
- `meta`

Those exclusions matter because OpenClaw mutates runtime-managed fields after startup. Without normalization, the same effective config would look different on every run.

Normal setup never replaces an existing VM config. It reads and updates only
ClawBox-managed provider, primary-model, and optional embeddings memory-search
keys through `openclaw config get` and `openclaw config set`. All other
OpenClaw settings remain user/OpenClaw-owned.

The managed primary keys are:

- `agents.defaults.model.primary`
- `models.providers.<provider>.baseUrl`
- `models.providers.<provider>.api`
- `models.providers.<provider>.models`

When embeddings are enabled, the managed memory-search keys are:

- `agents.defaults.memorySearch.enabled`
- `agents.defaults.memorySearch.provider`
- `agents.defaults.memorySearch.model`
- `agents.defaults.memorySearch.remote.baseUrl`
- `agents.defaults.memorySearch.remote.apiKey`

The memory-search provider is `openai-compatible`, the model value is the
embeddings GGUF basename, and the remote API key is `ollama-local` as ClawBox's
local/LAN marker.

`./clawbox openclaw reset` is the separate, default-no command for an
intentional full replacement; it backs up the existing config first when
present.

## Runtime states

`./clawbox setup` distinguishes between three VM states:

- OpenClaw not installed
- OpenClaw installed but not running
- OpenClaw actively running

Detection is performed over SSH inside a login shell.

`already running` requires a verified live gateway. ClawBox recognizes either
its own `com.clawbox.openclaw` service or OpenClaw's native
`ai.openclaw.gateway` LaunchAgent when the service has a running state, PID,
and gateway command evidence.

An active `com.clawbox.openclaw` launchd service is still inspected as supporting runtime state, but launchctl-loaded state alone does not count as an active runtime.

Stale artifacts alone do not count. A leftover plist, dead prior session, stale PID-like state, or other non-running residue must not be reported as an active runtime.
When the native OpenClaw LaunchAgent owns the gateway, setup and status report
that ownership and do not automatically stop it, replace it, or start the
ClawBox-managed service into its port.

## Restart behavior

Normal setup does not replace an existing config. If targeted settings changed,
setup reports that OpenClaw may reload automatically and offers an explicit,
default-no gateway restart prompt.

When targeted settings are unchanged:

- no overwrite prompt appears
- no restart is triggered for formatting-only or runtime-managed differences
- OpenClaw may still be started when it is installed, stopped, and `OPENCLAW_AUTOSTART=true`

When `OPENCLAW_AUTOSTART=true`, setup installs or refreshes a per-user launchd plist for OpenClaw in the VM, checks whether the `gui/$uid` launchd service is already loaded, safely boots out stale loaded state when needed, bootstraps the service once, and waits for both `launchctl print` and a live `openclaw gateway` PID before reporting success.

That plist is generated on the host and uploaded to the VM before `launchctl` runs. Runtime management does not rely on nested heredocs or multiline shell generation embedded directly inside quoted SSH commands.

If `launchctl bootstrap` fails, setup now surfaces the exact bootstrap command and stops instead of reporting a successful OpenClaw start.

OpenClaw runtime logs are written under the VM runtime checkout at `VM_RUNTIME_PATH/logs/runtime/openclaw.out.log` and `VM_RUNTIME_PATH/logs/runtime/openclaw.err.log`.

When `./clawbox model` explicitly syncs the VM default-model alias and the user
chooses to restart the VM gateway, ClawBox waits for a live gateway before
reporting success. A failed verification prints launchd, process, and log
diagnostics without changing broader VM configuration.

After setup actually restarts or updates the managed host `llama-server`, it
checks whether a verified ClawBox-managed VM gateway can still make a minimal
inference request to the host. A successful probe makes no VM change. A failed
probe offers a default-no restart of only that managed gateway; declining leaves
OpenClaw untouched and prints manual recovery guidance. This path never deploys
or replaces `openclaw.json`.

If the VM inference probe reaches `llama-server` while a large model is still
loading and receives llama.cpp's temporary `503 Loading model` response,
`./clawbox status` reports a waiting state and asks the user to retry shortly
instead of labeling the endpoint as broken.

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
