# LLaMA Server

`llama-server` is the host-side inference component for ClawBox.

Use `./clawbox model` after setup to choose which host model to manage.
`./clawbox model primary` changes only `MODEL_PATH` and restarts only the
primary managed host service. `./clawbox model embeddings` (or
`./clawbox model embedding`) configures or changes only the optional embeddings
instance. Neither path deploys VM artifacts or replaces OpenClaw configuration.
They may run targeted OpenClaw config sync for ClawBox-managed keys only:
primary sync covers the stable provider/model alias, and embeddings sync covers
OpenClaw `memorySearch`.
New ClawBox setups advertise the
stable OpenClaw model alias `clawbox/local`; the actual GGUF remains selected by
the host service.

Existing model-specific aliases remain unchanged until the user explicitly
accepts the separate default-no migration offered by `./clawbox model`.
That migration can separately update only the VM
`agents.defaults.model.primary` field through `openclaw config set`; it does
not replace the VM OpenClaw configuration file.

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
- `LLAMA_EXTRA_ARGS` (optional simple whitespace-separated flags appended after
  ClawBox's required arguments; quoting, embedded spaces, and shell expansion
  inside this value are not supported)
- `LLAMA_BASE_URL`

## Optional embeddings instance

`./clawbox setup` can create one additional host-only embeddings instance. It
uses `EMBEDDINGS_*` values, a separate `com.clawbox.llama.embeddings` launchd
label, separate runtime env/plist files and logs, and default port `11435`.
The embeddings GGUF and `EMBEDDINGS_LLAMA_EXTRA_ARGS` are independent of the
primary model; extra args support only simple whitespace-separated values.
Embeddings setup never replaces VM or OpenClaw configuration. Status reports it
only when `EMBEDDINGS_ENABLED=true`. When embeddings are enabled, ClawBox can
target OpenClaw memory search at the embeddings server with
`provider=openai-compatible`, the embeddings model filename as `model`,
`remote.baseUrl=EMBEDDINGS_LLAMA_BASE_URL`, and `remote.apiKey=ollama-local`.
Those targeted updates do not replace `~/.openclaw/openclaw.json`.
The configured embeddings base URL is authoritative. A server that responds on
host loopback but not at `EMBEDDINGS_LLAMA_BASE_URL` is reported as unhealthy,
because the VM and OpenClaw use the configured host-facing endpoint.

New setups default `LLAMA_PORT` to `11434` and `LLAMA_CTX` to `32768`.
Existing `.env` values are kept as-is. `OPENCLAW_MAX_TOKENS` is a separate
OpenClaw output-token setting and must be lower than the effective context
window. If llama-server reports that it capped the configured `LLAMA_CTX`, setup
uses the reported effective value for OpenClaw `contextWindow` without rewriting
the requested `.env` value.

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

Setup does not silently fall back between install methods. If a Homebrew install
fails and source-build prerequisites are available, setup preserves the brew
output in `logs/setup/homebrew-install-*.log`, reports the concise failure
category, and asks before cloning/building llama.cpp locally.

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
- setup prints the managed stdout and stderr log paths before the readiness wait so startup failures can be inspected after the fact
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
