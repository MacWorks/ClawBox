source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/output.sh"

sync_openclaw_config() {
  ssh_run_quiet "mkdir -p $REMOTE_CONFIG_DIR"

  if ssh_exec "test -f $REMOTE_CONFIG_PATH"; then
    if configs_match; then
      :
    else
      warn "Config differs from existing ~/.openclaw/openclaw.json."
      warn "Overwriting config may restart OpenClaw."
      prompt_yes_no 'Overwrite?' 'n'
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