# Launchd

ClawBox uses launchd on the host for two separate purposes.

## Host inference service

The host-side `llama-server` process can be managed by either a system LaunchDaemon or a user LaunchAgent.

System mode for admin users:

- runs `/usr/local/bin/clawbox-llama-wrapper.sh`
- starts at boot
- keeps the wrapper alive
- writes logs to `logs/runtime/clawbox-llama-system.out.log` and `logs/runtime/clawbox-llama-system.err.log`

User mode for non-admin users:

- runs `~/Library/Application Support/ClawBox/bin/clawbox-llama-wrapper.sh`
- starts only when that user is logged in
- keeps the wrapper alive through a LaunchAgent
- writes logs to `logs/runtime/clawbox-llama-user.out.log` and `logs/runtime/clawbox-llama-user.err.log`

`./clawbox setup` selects the appropriate launchd mode interactively. The selected mode installs the wrapper, installs the runtime env file, starts the service, and verifies that it started.

## Optional VM auto-start

`./clawbox setup` can also install a per-user LaunchAgent at login to start the UTM VM automatically.

This is optional and controlled interactively from the main setup flow. It depends on `VM_MACHINE_NAME` in `.env`.

The optional VM auto-start LaunchAgent writes its diagnostics to `logs/vm/clawbox-startutmvm.out.log` and `logs/vm/clawbox-startutmvm.err.log`.

## Related configuration

- `LLAMA_BIN`
- `MODEL_PATH`
- `LLAMA_HOST`
- `LLAMA_PORT`
- `LLAMA_CTX`
- `VM_MACHINE_NAME`

## Related docs

- `docs/components/llama-server.md`
- `docs/setup/host.md`
