# LLaMA Server

`llama-server` is the host-side inference component for ClawBox.

Use `./clawbox model` to switch the managed host GGUF after setup. It changes
only `MODEL_PATH` and restarts the managed host service; it does not deploy VM
artifacts or replace OpenClaw configuration. New ClawBox setups advertise the
stable OpenClaw model alias `clawbox/local`; the actual GGUF remains selected by
the host service.

Existing model-specific aliases remain unchanged until the user explicitly
accepts the separate default-no migration offered by `./clawbox model`.

## Purpose

It provides the OpenAI-compatible HTTP endpoint that the VM-side OpenClaw process uses for model inference.

## Configuration

The host `llama-server` process is configured from the repository root `.env` file.

`./clawbox setup` writes the runtime subset of that configuration to a mode-specific env file for launchd:

- system mode: `/usr/local/etc/clawbox.env`
- user mode: `~/Library/Application Support/ClawBox/clawbox.env`

Relevant values:

- `LLAMA_BIN`
- `MODEL_PATH`
- `LLAMA_HOST`
- `LLAMA_PORT`
- `LLAMA_CTX`
- `LLAMA_BASE_URL`

New setups default `LLAMA_PORT` to `11434`. Existing `.env` values are kept as-is.

Before ClawBox starts or reconfigures any managed host service, setup checks `http://HOST_IP:LLAMA_PORT/v1/models` and requires the response to parse as valid JSON. After starting a managed service, setup first waits for the TCP port to open and then keeps polling that API until it responds or the 120 second timeout expires.

- If that API is already responding, setup lets you reuse the existing instance, stop and replace it only when the current user owns it, choose a different port, or exit without changing launchd state.
- If the API is not responding but `lsof` sees a listener on the configured port, setup prints a warning with the raw listener output but does not treat that alone as authoritative.

Host dependency hierarchy:

- Xcode Command Line Tools are required
- Homebrew depends on Xcode Command Line Tools
- Homebrew-based `llama.cpp` installation depends on Homebrew
- HTTPS source builds require `cmake`, which also depends on Xcode Command Line Tools

If `LLAMA_BIN` is missing, setup offers these explicit choices after user approval:

- Homebrew install, which is the preferred method when Homebrew is installed and writable
- HTTPS source build under `$HOME/ai/llama.cpp`, which requires `cmake`
- manual binary path entry

Setup does not automatically fall back between install methods.

If Homebrew is installed but not writable by the current user, setup warns and does not attempt to repair permissions automatically.

## Wrapper behavior

`host/scripts/llama-wrapper.sh` does the following:

- loads the env file path passed by launchd
- exits early if `llama-server` is already running
- verifies that `LLAMA_BIN` is executable
- verifies that `MODEL_PATH` exists
- starts `llama-server` with the configured host, port, and context size

## Expected verification

A healthy host inference service should satisfy all of the following:

- the `llama-server` API responds at `http://HOST_IP:LLAMA_PORT/v1/models` with valid JSON
- if startup validation fails after waiting for the TCP port and API readiness, setup offers retry, port change, log viewing, or graceful exit instead of silently continuing
- the VM can reach `LLAMA_BASE_URL`

`./scripts/status.sh` treats an opted-in external instance as healthy when `LLAMA_EXTERNAL=true` and the configured API responds. If the API responds but that opt-in flag is not set, the script reports that the instance is not managed by this user and instructs the user to re-run setup and accept the external instance explicitly.

When setup reuses an existing current-user ClawBox-managed LaunchAgent, it keeps `LLAMA_EXTERNAL=false` and reports that instance as managed rather than external.

For ClawBox-managed services, `./scripts/status.sh` validates the active launchd mode using the matching managed artifacts for that mode:

- system mode: LaunchDaemon plist at `/Library/LaunchDaemons/com.clawbox.llama.plist` and runtime env at `/usr/local/etc/clawbox.env`
- user mode: LaunchAgent plist at `~/Library/LaunchAgents/com.clawbox.llama.plist` and runtime env at `~/Library/Application Support/ClawBox/clawbox.env`

VM-side status checks use noninteractive SSH with a short connect timeout so degraded SSH connectivity fails fast instead of prompting or hanging inside `./scripts/status.sh`.

## Related docs

- `docs/components/firewall.md`
- `docs/components/launchd.md`
- `docs/setup/host.md`
