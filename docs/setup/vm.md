# VM Setup

This document describes the VM requirements for ClawBox.

## VM requirements

The VM is responsible only for running OpenClaw. It does not run model inference.

Recommended baseline:

- macOS VM created in UTM
- Shared Network enabled in UTM
- Remote Login enabled in the VM so the host can use SSH
- standard Homebrew install locations available if you provision through Homebrew on Apple Silicon

## Determine the VM IP address

Inside the VM, try:

    ipconfig getifaddr en0

The active interface is typically `en0` on macOS, but may vary.

If that does not return an address, use:

    ifconfig

Find the interface address on the shared subnet (commonly `192.168.64.x` in UTM).

From the host, verify connectivity:

    ping vm-ip

Replace `vm-ip` with the address you found.

You should receive replies. If not, check UTM networking settings.

## SSH setup

1. Generate an SSH key on the host if you do not already have one:

    ssh-keygen -t ed25519

 Press ENTER twice to accept the default path and no passphrase.

2. Copy the public key to the VM:

    ssh-copy-id user@vm-ip

`user` is the VM account username.

Concrete example:

    ssh-copy-id user@192.168.64.2

3. If `ssh-copy-id` is not available, use this fallback:

    cat ~/.ssh/id_ed25519.pub | ssh user@vm-ip 'mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys'

4. Verify passwordless SSH login:

    ssh user@vm-ip

No password prompt should appear.

If SSH prompts for a password, key setup is not complete.

5. Verify that noninteractive SSH commands work:

    ssh user@vm-ip 'echo OK'

## Requirements Summary

- `VM_HOST` must match `user@vm-ip`
- SSH must be passwordless
- noninteractive SSH commands must work

## Before running setup

- The VM should have an IP address
- Remote Login should be enabled in the VM
- Passwordless SSH is still the preferred steady state

During setup, ClawBox distinguishes between a stopped VM, a booting VM, a running VM with SSH unavailable, an invalid or unreachable VM address, and a fully ready VM.

- If the VM is stopped, setup can offer to start it.
- If setup starts the VM itself, it now separates the phases of launching the VM, waiting for VM runtime evidence, waiting for VM network reachability, and then waiting for SSH. These phases use one updating spinner line in an interactive terminal and a single start line plus a single result line in noninteractive output.
- Launching the UTM application alone is not treated as proof that the VM itself is powered on.
- UTM runtime state detection through `utmctl list` and `utmctl status` is treated as authoritative for VM power and running state.
- The network phase uses a short bounded TCP probe to port 22 so network readiness is measured separately from the slower SSH authentication probe.
- When the network phase times out, the stage emits one final `VM network was not detected within the expected time window.` result line and the higher-level repair flow does not print the same failure headline again.
- If ClawBox itself just started the VM and runtime was detected, a bounded recovery menu is shown instead of exiting immediately. That recovery menu can continue waiting, retry the network check, attempt VM IP discovery, or abort setup.
- If VM IP recovery succeeds, setup does not return to the network phase. It transitions directly into SSH-stage handling so the next outcomes are SSH readiness, SSH refusal guidance, SSH bootstrap, or manual SSH recovery.
- If the current VM IP address is still unreachable after the VM is running, setup first tries `utmctl ip-address <vm-name>`. UTM documents this as guest-agent-backed `query ip` data, which means it is authoritative only when the QEMU guest agent is installed and running.
- `utmctl ip-address` is not universally reliable for Apple Virtualization macOS guests, so ClawBox does not treat it as a guaranteed guest-IP source for those guests.
- If `utmctl ip-address` does not return a usable guest IPv4 address, setup falls back to a short bounded discovery pass across the expected shared subnet, which remains the recovery path for macOS guest networking.
- If the current VM address is invalid, unreachable, refusing connections, or timing out, setup reports that specific condition before offering any SSH repair flow.
- If port 22 is reachable but refusing connections, setup treats that as first-run onboarding and prompts the user to enable Remote Login inside the guest before retrying only the SSH readiness stage.
- If SSH transport is reachable and password authentication works but key authentication is not configured, setup reports this as a bootstrap-needed state instead of an SSH transport failure:
    - `SSH connectivity is working.`
    - `Passwordless SSH authentication is not yet configured.`
    - setup then offers automatic SSH key bootstrap.
- If key-based SSH authentication is already configured, setup continues automatically and does not prompt for SSH bootstrap again.
- Setup uses short bounded probes during onboarding so incorrect VM IPs, missing network reachability, and closed SSH ports fail quickly instead of looking like a hang.

## UTM metadata note

UTM exposes VM state through `utmctl list` and `utmctl status`, and ClawBox treats that runtime information as authoritative. UTM also exposes guest IP addresses through `utmctl ip-address <vm-name>`, but UTM's scripting reference states that guest-side `query ip` requires the QEMU guest agent.

In practice this means:

- QEMU guests with the guest agent installed can provide authoritative guest IP metadata through UTM.
- Apple Virtualization guests and guests without the QEMU guest agent do not provide a universally reliable guest IP through UTM alone.
- ClawBox therefore prefers `utmctl ip-address` when it returns usable data, and otherwise keeps the existing bounded subnet-based recovery flow as the fallback.

## Runtime directory

`VM_RUNTIME_PATH` is a staging directory inside the VM.

Requirements:

- it must be an absolute path
- it must point to a writable location for the VM user
- it must not rely on `~`

Host automation ensures that `vm-provision.sh` is placed there.  
The authoritative OpenClaw config remains:

    ~/.openclaw/openclaw.json

## Networking expectations

The intended deployment model is:

- host runs `llama-server`
- host setup starts and verifies `openclaw gateway` inside the VM through the
  intended launchd runtime
- VM calls the host's OpenAI-compatible endpoint using `LLAMA_BASE_URL`

With UTM Shared Network:

- the VM should be able to reach the host `LLAMA_PORT` endpoint on the shared subnet

## Related docs

- `docs/setup/host.md`
- `docs/setup/provisioning.md`
- `docs/components/firewall.md`
- `docs/components/runtime.md`
