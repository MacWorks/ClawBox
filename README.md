# ClawBox

ClawBox runs OpenClaw inside a macOS VM while keeping model inference on the host with `llama-server`. The repository provides a repeatable host setup flow, VM provisioning script, and documentation for the host, VM, and runtime boundaries.

The host owns `.env`, config generation, SSH-based deployment, and host inference services. The VM owns OpenClaw installation and `openclaw gateway` execution.

## Security Model

ClawBox isolates OpenClaw inside a dedicated macOS virtual machine.

The host retains control of model inference, configuration generation, deployment, and runtime artifacts. OpenClaw executes inside the VM and can be granted access to VM resources according to the user's preferences.

This design allows users to experiment with OpenClaw in an environment that is separated from the host operating system while keeping model inference on the host.

## Project Status

Early development / pre-release.

Interfaces, setup flow, and documentation may change between releases.

## Prerequisites

Before you run any setup command, make sure all of the following already exist:

- a macOS host
- Xcode Command Line Tools installed on the host
- UTM installed on the host
- a macOS VM created in UTM
- the VM has a user account you can log into
- SSH enabled in the VM through Remote Login
- network connectivity from the host to the VM once the VM is running

Setup can assist with VM startup, SSH host-key trust, and SSH key bootstrap.
Passwordless SSH is the preferred steady state.

Host dependency chain:

- Xcode Command Line Tools are required
- Homebrew depends on Xcode Command Line Tools
- `llama.cpp` installation through Homebrew depends on Homebrew
- source builds require `cmake`, which also depends on Xcode Command Line Tools

## VM Setup

Create and prepare the VM before cloning the repository or running host setup:

1. Create a macOS VM in UTM.
2. Use Shared Networking so the VM can reach the host and the host can SSH to the VM.
3. Boot the VM and create a user account.
4. Enable Remote Login inside the VM.
5. Determine the VM IP address.
6. From the host, test SSH when the VM is running:

```bash
ssh user@vm-ip
```

If this step fails, setup can still guide SSH onboarding, but fixing Remote
Login and basic reachability first makes the setup flow smoother.

See `docs/setup/vm.md` for the full VM setup details.

## Architecture

- Host: stores `.env`, runs `llama-server`, generates OpenClaw config, pushes runtime artifacts over SSH
- VM: runs `vm-provision.sh` manually when needed, then runs `openclaw gateway`
  directly or through the VM user launchd service configured by setup
- Network path: VM OpenClaw process calls the host `llama-server` endpoint through `LLAMA_BASE_URL`

See `docs/architecture/overview.md` for the full architecture summary.

## Setup

1. Review the prerequisites.
2. Complete VM setup.
3. Clone the repository.
4. Run `./clawbox setup` from the repository root on the host.
5. Inside the VM, change to `VM_RUNTIME_PATH` and run `./vm-provision.sh`.
6. Return to the host setup prompt and confirm provisioning completed so setup
   can continue into runtime service configuration.

### Step 1: Review prerequisites

Confirm that the host, VM, networking, and SSH requirements in the prerequisites section are already satisfied.

### Step 2: Complete VM setup

Create the VM in UTM, enable Remote Login, determine the VM IP when needed, and
verify that this command works from the host if possible:

```bash
ssh user@vm-ip
```

If SSH does not work yet, setup can assist with first-contact host-key trust and
SSH key bootstrap. See `docs/setup/vm.md` for detailed VM instructions.

### Step 3: Clone the repository

```bash
git clone git@github.com:MacWorks/ClawBox.git
cd ClawBox
```

### Step 4: Run the host setup flow

```bash
./clawbox setup
```

What to expect:

- if `.env` is missing or incomplete, the script prompts for the required values and writes a populated `.env`
- the script prompts for a `llama-server` install mode and uses a system-wide LaunchDaemon for admin users or a per-user LaunchAgent for non-admin users
- the script offers `llama.cpp` installation through Homebrew, source build through HTTPS, or manual binary path entry if `LLAMA_BIN` is missing
- the script does not automatically fall back between install methods; you must choose one explicitly
- if Homebrew is installed but not writable, the script warns and does not fix permissions automatically
- the script installs the wrapper, runtime env file, and launchd plist for the selected mode
- the script starts the host `llama-server` service and verifies that the process is running and the port is open
- the script validates host tools and SSH access before doing remote work
- if the VM has no `~/.openclaw/openclaw.json`, the script installs an initial minimal OpenClaw config
- if the VM already has `~/.openclaw/openclaw.json`, the script preserves it and updates only ClawBox-managed keys with `openclaw config set`
- the script copies `vm-provision.sh` to `VM_RUNTIME_PATH` when needed
- if OpenClaw is not installed, the script prints VM-local provisioning
  instructions and prompts `Provisioning completed inside the VM? [Y/n]:`
- after you confirm provisioning completed, setup refreshes VM runtime state,
  offers to run the interactive OpenClaw onboarding flow, and then continues
  into launchd/runtime service setup
- after an actual managed `llama-server` restart/update, setup may offer a
  default-no VM OpenClaw gateway restart only when the running, ClawBox-managed
  gateway cannot complete a VM-to-host inference probe; this does not rewrite
  VM OpenClaw configuration

The default `llama-server` port for new setups is `11434`. Existing `.env` values are preserved.

Host-side tool requirements for `llama-server` setup:

- Homebrew is the preferred install method when it is available and writable
- `cmake` is required only for the HTTPS source build path
- manual binary path entry avoids automatic installation entirely

### Step 5: Provision the VM

Inside the VM:

```bash
cd "$VM_RUNTIME_PATH"
./vm-provision.sh
```

Provisioning is one-time and safe to repeat. It installs Homebrew when needed, ensures Node is available, installs OpenClaw, and verifies that `openclaw` is present in PATH.

### Step 6: Continue host setup

Return to the host terminal running `./clawbox setup` and answer yes when it
asks whether provisioning completed inside the VM. Once it confirms OpenClaw is
available, setup offers to run `openclaw onboard` interactively over SSH. You
may decline and use the displayed command later. If onboarding opens the
terminal agent chat, type `/exit` when finished so ClawBox setup can continue.
Setup then continues with VM runtime launchd setup.

## Verification

For model/build-specific `llama-server` flags, set `LLAMA_EXTRA_ARGS` in
`.env`, for example `LLAMA_EXTRA_ARGS="-ngl 99 --jinja -fa on"`. This supports
simple whitespace-separated arguments only; quoted values or embedded spaces
are not supported.

To switch only the host GGUF model after setup, run `./clawbox model`. It
updates `MODEL_PATH`, restarts the managed host `llama-server`, and leaves VM
provisioning and the OpenClaw config file intact. It may verify and correct
only ClawBox-managed OpenClaw provider keys such as `clawbox/local` with
targeted `openclaw config set` calls. After a successful interactive primary
model switch, ClawBox offers a Fast/Full/Skip qualification menu. The default
is Skip, and declining does not affect the completed switch. Fast is a reduced
post-switch validation profile; Full is the complete qualification suite.

To run the VM-side model qualification framework against the currently
configured host model behind the OpenClaw alias, use:

```bash
./clawbox qualify
./clawbox qualify --profile fast
./clawbox qualify --profile full
./clawbox qualify --profile fast --scenario 01-tool-reliability
./clawbox qualify history
./clawbox qualify compare
./clawbox qualify report --latest
./clawbox qualify badge --latest
```

Without `--profile`, qualification uses the Full profile. The report identifies
the selected profile and coverage so Fast results are not confused with Full
results. It also shows both the actual configured/running GGUF model and the
stable OpenClaw alias such as `clawbox/local`. Qualification artifacts are stored under
`~/.openclaw/workspace/.clawbox/qualification/runs/` inside the VM. The command
also maintains a compact host-side history index under `data/qualification/`
for history display, comparisons, Markdown reports, badges, and model-menu
qualification summaries. That directory is runtime data and is ignored by Git.
The command does not switch models, replace OpenClaw config, rerun onboarding,
or install inference software in the VM. See `docs/qualification.md`.

### Optional embeddings server

Setup can optionally manage a second, host-only `llama-server` for embeddings.
It has a separate GGUF, launchd service, logs, and endpoint (default port
`11435`), while the primary chat/inference server stays unchanged. It never
changes VM provisioning, replaces OpenClaw configuration, or alters onboarding.
When enabled, ClawBox can sync only OpenClaw `memorySearch` keys to point at the
embeddings endpoint. Its extra args default to `--embedding`; like primary
`LLAMA_EXTRA_ARGS`, only simple whitespace-separated arguments are supported.

Use `./clawbox model primary` to switch only the primary model, or
`./clawbox model embeddings` (or `./clawbox model embedding`) to configure/switch only the
embeddings model. The embeddings command does not replace VM/OpenClaw config;
it may update only the ClawBox-managed OpenClaw `memorySearch` values. The
memory-search remote API key is set to `ollama-local` as ClawBox's local/LAN
embeddings marker.

For existing filename-derived aliases, `./clawbox model` offers a separate
default-no migration to `clawbox/local`. That migration changes only `.env`;
it then separately offers a targeted VM update for
`agents.defaults.model.primary`.

Normal setup preserves an existing VM `~/.openclaw/openclaw.json`. The explicit
full-reset path is:

```bash
./clawbox openclaw reset
```

That command warns loudly, defaults to No, backs up the existing VM config when
present, and then replaces it with ClawBox's minimal generated config only if
you confirm.

Host checks:

```bash
curl "${LLAMA_BASE_URL%/v1}/v1/models"
```

Large GGUF models may take time to finish loading after launchd starts
`llama-server`. During that window `./clawbox status` reports `RESULT: WAITING`
when the VM inference probe receives llama.cpp's temporary `Loading model`
response; retry status shortly.

VM checks:

```bash
command -v openclaw
openclaw --version
pgrep -f openclaw
```

Expected outcomes:

- `./clawbox setup` completes without prompting again on unchanged reruns
- `command -v openclaw` returns a valid executable path inside the VM
- `openclaw --version` returns a version string
- OpenClaw is running in the VM, usually through the VM user launchd service
- the host `llama-server` endpoint responds successfully
- `./clawbox status` reports `RESULT: HEALTHY`

## Documentation

- `docs/setup/host.md`
- `docs/setup/vm.md`
- `docs/setup/provisioning.md`
- `docs/components/runtime.md`
- `docs/components/llama-server.md`
- `docs/components/firewall.md` (documents the deprecated manual firewall helper and the remaining VM subnet metadata)
- `docs/components/launchd.md`
- `docs/contract/clawbox-contract.md`
