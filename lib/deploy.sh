source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/output.sh"

sync_openclaw_config() {
  ssh_run_quiet "mkdir -p $REMOTE_CONFIG_DIR"

  if ssh_exec "test -f $REMOTE_CONFIG_PATH"; then
    if configs_match; then
      :
    else
      warn 'WARNING'
      blank_line
      warn 'This operation will replace the VM OpenClaw config:'
      warn '~/.openclaw/openclaw.json'
      blank_line
      warn 'Replacing this file may remove:'
      warn '- provider configuration'
      warn '- model configuration'
      warn '- onboarding state'
      warn '- custom OpenClaw settings'
      if command -v openclaw_runtime_is_active >/dev/null 2>&1 && openclaw_runtime_is_active; then
        warn "OpenClaw appears to be running; applying this change can restart the gateway."
      fi
      prompt_yes_no 'Continue?' 'n'
      OVERWRITE_CONFIG="$REPLY"

      if is_yes "$OVERWRITE_CONFIG"; then
        out "Uploading config..."
        scp -O -q "$CONFIG_PATH" "$VM_HOST:~/.openclaw/openclaw.json" </dev/null
        ssh_exec "test -f $REMOTE_CONFIG_PATH"
        CONFIG_OVERWRITTEN=true
      fi
    fi
  else
    out "Uploading config..."
    scp -O -q "$CONFIG_PATH" "$VM_HOST:~/.openclaw/openclaw.json" </dev/null
    ssh_exec "test -f $REMOTE_CONFIG_PATH"
  fi
}
