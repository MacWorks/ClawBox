# Host Setup

This document describes the host side of ClawBox.

## What `./clawbox setup` does

`./clawbox setup` is the main host entry point. It does the following:

- bootstraps `.env` values interactively when required
- runs a VM platform check before network prompts so first-run users can confirm Apple Silicon, UTM, and detect existing `.utm` VMs before continuing
- offers a distinct VM detection flow when macOS privacy settings block access to the sandboxed UTM documents directory, explains how to grant Full Disk Access to the app running setup, attempts to open the Full Disk Access settings pane, lets you continue with manual VM configuration, or exits gracefully
- reports when the VM is running but SSH is not yet reachable instead of treating SSH failure as proof that the VM is stopped, including cases where another macOS user owns the running UTM process and `utmctl list` is not visible to the current setup user
- prompts for a `llama-server` install mode
- checks for healthy reusable `llama-server` instances before host-side binary installability checks, including listeners discovered on alternate local ports
- when the configured/default endpoint is unhealthy, continues scanning alternate listening ports, explicitly reports that the configured endpoint is unhealthy, and states when setup switches to a discovered healthy port before entering any binary install flow
- treats a `llama-server` endpoint as healthy only when both checks pass: a listening socket exists on the candidate port and `http://HOST_IP:LLAMA_PORT/v1/models` returns valid JSON
- classifies runtime state as unhealthy (not reusable) when process presence, launchd load state, listener state, and endpoint health disagree (for example: launchd loaded but no listener, or process present but health endpoint failing)
- classifies an already running `llama-server` by owner and runtime context when possible, including current-user sessions, other-user sessions, inferred cross-user sessions when the API is reachable but macOS hides the owning process, LaunchAgent or LaunchDaemon services, ClawBox-managed services, and unknown ownership
- treats the inferred `cross-user-session` case as non-durable because the service is reachable and listening locally but the owning process is not visible from the current macOS account, which usually means another logged-in user session or another opaque per-user runtime context
- treats instances owned by another macOS user account, hidden ownership, or other non-controllable runtimes as read-only from the current account and routes setup to a separate ClawBox-managed instance on another port instead of pretending the running instance can be stopped and replaced
- if the selected alternate ClawBox-managed port is already served by a current-user ClawBox-managed LaunchAgent, offers explicit no-downtime reuse of that running instance first and keeps restart as a separate second option instead of forcing another port-selection loop
- only marks `Use existing instance` as recommended when the detected `llama-server` is operationally durable, and otherwise recommends moving to a ClawBox-managed instance or a different port instead
- lets you reuse an already running `llama-server` instance, stop and replace it only when the current user owns it, choose a different port, or exit setup gracefully
- detects Homebrew in common macOS locations even when it is missing from the current account `PATH`, temporarily uses the discovered installation for setup, and prints the exact shell commands needed to make the Homebrew path persistent for future sessions
- caches Homebrew discovery during a setup run so repeated checks do not keep re-scanning the same installation state unless setup changes the active Homebrew path
- classifies Homebrew install failures into actionable categories such as permissions, lock contention, missing Xcode Command Line Tools, missing brew, network failures, and unavailable formulae instead of collapsing them into a generic environment failure
- if a shared Homebrew installation already contains `llama.cpp` but the current macOS account cannot modify it, explains that the existing installation may still be reusable from this account and points the user toward binary reuse, another port, or fixing Homebrew ownership
- when the user chooses `Use existing llama-server binary`, attempts to discover reusable binaries in `PATH`, common Homebrew locations, `~/.local/bin`, and known local `llama.cpp` build outputs before falling back to a manual path prompt
- installs the system-wide `llama-server` wrapper at `/usr/local/bin/clawbox-llama-wrapper.sh` when system mode is selected for an admin user
- installs the user-only `llama-server` wrapper at `~/Library/Application Support/ClawBox/bin/clawbox-llama-wrapper.sh` when user mode is selected or required for a non-admin user
- installs the runtime env file for the selected mode
- installs and starts the matching LaunchDaemon or LaunchAgent for the selected mode
- can install `llama.cpp` through Homebrew or build it from source with HTTPS and `cmake` when `LLAMA_BIN` is missing and the user approves installation
- validates the host `llama-server` startup in two phases after launch by waiting for the TCP port and then polling `http://HOST_IP:LLAMA_PORT/v1/models` for valid JSON, and offers retry, port change, log viewing, or graceful exit on failure
- validates host prerequisites before doing remote work
- when an existing VM auto-start runtime service is already present, distinguishes between keeping that managed runtime service and skipping runtime-service management for the current setup run
- when a chosen models directory contains no supported `.gguf` files, keeps setup in an explicit recovery menu that allows entering a different directory, entering a full model path manually, re-scanning the current directory, or exiting setup gracefully instead of silently collapsing into manual file mode
- checks SSH connectivity to the VM
- detects whether OpenClaw is installed and running on the VM
- generates `vm/runtime/openclaw.json` on the host
- compares the generated config to the VM's authoritative config at `~/.openclaw/openclaw.json`
- uploads the config only when needed
- copies `vm-provision.sh` to the VM runtime path when missing
- if OpenClaw is not installed yet, presents VM-local provisioning guidance and
  prompts for confirmation when provisioning has completed inside the VM
- optionally starts OpenClaw as a VM user launchd service when `OPENCLAW_AUTOSTART=true`

It does not install OpenClaw inside the VM or run `vm-provision.sh` remotely.
Provisioning activity remains manual, VM-local, visible to the user, and
fail-fast.

## Host prerequisites

You need the following on the host before running `./clawbox setup`:

- macOS host with the repository checked out locally
- Xcode Command Line Tools installed
- a reachable macOS VM
- UTM installed at `/Applications/UTM.app`
- for guided VM detection, at least one configured UTM VM bundle under `~/Library/Containers/com.utmapp.UTM/Data/Documents/*.utm`
- passwordless SSH access to the VM
- `jq`, `ssh`, `scp`, and `shasum` available on the host
- a model file at `MODEL_PATH`

Dependency order:

- Xcode Command Line Tools are required first
- Homebrew depends on Xcode Command Line Tools
- `llama.cpp` installation through Homebrew depends on Homebrew
- `cmake` is required only for source builds and also depends on Xcode Command Line Tools

Additional host tools by install method:

- Homebrew install: Homebrew must be installed and writable by the current user
- if Homebrew exists at `/opt/homebrew/bin/brew` or `/usr/local/bin/brew` but is missing from `PATH`, setup can still use it for the current run and will print the exact `brew shellenv` command needed to persist the fix
- on Macs shared by multiple user accounts, Homebrew may already exist system-wide while remaining unwritable from a secondary standard-user account; setup now reports that situation explicitly and avoids claiming that automatic installation is impossible when the real problem is shared-ownership permissions
- source build: `git` and `cmake` must be available
- manual binary path: no automatic install tools are required

If `.env` is missing or contains placeholders, `./clawbox setup` prompts for the required values and writes a new `.env` from `.env.example`.

## Environment expectations

ClawBox uses the repository root `.env` file as the host-side source of truth.

Important values:

- `VM_HOST`: SSH target in `user@ip` form
- `VM_RUNTIME_PATH`: absolute staging path inside the VM
- `VM_MACHINE_NAME`: UTM VM name used for optional login auto-start
- `LLAMA_BIN`: absolute path to the host `llama-server` binary
- `MODEL_PATH`: absolute path to the model file used by `llama-server`
- `LLAMA_HOST`, `LLAMA_PORT`, `LLAMA_CTX`, `LLAMA_BASE_URL`: host inference settings, with a default port of `11434` for new setups
- `LLAMA_EXTERNAL`: whether setup explicitly accepted an externally managed `llama-server` instance for the configured endpoint
- `LLAMA_EXTERNAL` remains `false` when setup reuses an existing current-user ClawBox-managed instance on the configured port
- `FIREWALL_SHARED_SUBNET`: shared-network hint used by VM SSH recovery and VM IP discovery; the legacy variable name remains for compatibility
- `OPENCLAW_PROVIDER_NAME`, `OPENCLAW_DEFAULT_MODEL`, `OPENCLAW_AUTOSTART`: OpenClaw integration settings

Use `.env.example` as the reference for required keys and expected value formats.

Install mode behavior:

- admin users can choose system-wide install, which requires sudo, uses a LaunchDaemon, and starts at boot
- non-admin users must use user-level install, which uses a LaunchAgent and runs only while that user is logged in

`llama.cpp` install choices:

- Homebrew install is preferred when Homebrew is installed and writable
- HTTPS source build requires `cmake`
- manual binary path entry is available when you want to manage `llama-server` yourself
- setup does not automatically fall back between install methods
- if Homebrew is installed but not writable, setup warns and leaves permission fixes to the user

## What to expect on a successful run

A successful run of `./clawbox setup` should:

- leave `.env` populated with concrete values
- install either the system-wide wrapper and LaunchDaemon or the user-only wrapper and LaunchAgent
- install the runtime env file with only the values needed by the wrapper for the selected mode
- start `llama-server` on the host and bind `LLAMA_PORT`
- ensure the VM has `vm-provision.sh` at `VM_RUNTIME_PATH`
- if provisioning is required, present VM-local provisioning guidance and wait
  for the user to confirm completion
- ensure the VM's authoritative OpenClaw config is present at `~/.openclaw/openclaw.json`
- report whether OpenClaw is missing, stopped, or already running

When `OPENCLAW_AUTOSTART=true`, setup writes or refreshes a per-user OpenClaw launchd plist in the VM, starts it with `launchctl`, and waits for that service to become active before continuing.

If OpenClaw is not yet installed, setup guides the user through manual
provisioning inside the VM. After confirmation, setup refreshes runtime state and
continues without requiring a second setup run.

In all cases, provisioning remains separate from runtime execution and must remain visible and fail-fast.

## Related docs

- `docs/setup/vm.md`
- `docs/setup/provisioning.md`
- `docs/components/runtime.md`
- `docs/components/llama-server.md`
