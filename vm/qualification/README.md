# ClawBox VM Qualification Suite

This directory is installed into the VM at:

```text
~/.openclaw/workspace/.clawbox/qualification
```

The runner keeps per-run artifacts under `runs/<run-id>/`. Scenarios are
isolated from each other and emit JSON result documents consumed by the host
`./clawbox qualify` command.

The production scenarios invoke:

```bash
openclaw agent --session-id "$session" --timeout <seconds> --json --message "$prompt"
```

They read execution evidence from OpenClaw session trajectory/transcript files
under `$HOME/.openclaw/agents/main/sessions/`. Missing or malformed evidence is
an infrastructure `ERROR`.

The original prototype sources are retained in `prototype/model-qualification/`
for review and comparison. They are not installed in this VM payload.
