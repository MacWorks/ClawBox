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

During setup, ClawBox distinguishes between selected-VM runtime evidence, guest
network evidence, SSH service evidence, and UTM automation availability. A failed
or blocked selected-VM inspection is treated as `unknown`, not as stopped.

Setup can therefore distinguish a stopped selected VM, a booting selected VM, a
VM whose configured guest address is reachable but whose SSH service is disabled,
an invalid or unreachable VM address, and a fully ready VM.

- If the VM is stopped, setup can offer to start it.
- If setup starts the VM itself, it now separates the phases of launching the VM, waiting for VM runtime evidence, waiting for VM network reachability, and then waiting for SSH. These phases use one updating spinner line in an interactive terminal and a single start line plus a single result line in noninteractive output.
- Launching the UTM application alone is not treated as proof that the VM itself is powered on.
- UTM runtime state detection for the selected VM is treated as authoritative for VM power and running state.
- The selected VM is reported as stopped only when selected-VM-specific UTM evidence explicitly says it is stopped.
- If UTM Automation is denied, times out, or is unavailable, setup keeps selected-VM runtime as unknown and uses network/SSH evidence from the configured VM address before choosing a recovery path.
- A generic virtualization process on the Mac is advisory only. It may explain why UTM or virtualization appears active, but it is not treated as proof that the selected VM is running.
- The network phase uses a short bounded TCP probe to port 22 so network readiness is measured separately from the slower SSH authentication probe.
- When the network phase times out, the stage emits one final `VM network was not detected within the expected time window.` result line and the higher-level repair flow does not print the same failure headline again.
- If ClawBox itself tried to start the selected VM and SSH readiness still fails, a bounded recovery menu is shown instead of exiting immediately. That recovery menu can try starting the selected VM again, recheck after manual startup, rediscover VM addresses, accept a manually entered address, print manual SSH guidance, or exit setup.
- When you choose the manual-start recheck path, setup does not try to start UTM again. It performs bounded checks against the configured VM address and treats network/SSH readiness as enough evidence to continue even if UTM Automation remains blocked.
- If the selected VM is still known to be stopped, address discovery is not treated as authoritative. Setup explains that discovery may be incomplete and asks for confirmation before running it.
- If the configured VM address is already network-reachable, setup keeps that address and does not replace it through discovery.
- External UTM commands are bounded so `utmctl`, AppleScript, or `open -a UTM` cannot leave setup waiting indefinitely.
- If VM IP recovery succeeds, setup does not return to the network phase. It transitions directly into SSH-stage handling so the next outcomes are SSH readiness, SSH refusal guidance, SSH bootstrap, or manual SSH recovery.
- If the current VM IP address is still unreachable after the selected VM is confirmed running, setup first tries `utmctl ip-address <vm-name>`. UTM documents this as guest-agent-backed `query ip` data, which means it is authoritative only when the QEMU guest agent is installed and running.
- `utmctl ip-address` is not universally reliable for Apple Virtualization macOS guests, so ClawBox does not treat it as a guaranteed guest-IP source for those guests.
- If `utmctl ip-address` does not return a usable guest IPv4 address, setup falls back to a short bounded discovery pass across the expected shared subnet, which remains the recovery path for macOS guest networking.
- If the current VM address is invalid, unreachable, refusing connections, or timing out, setup reports that specific condition before offering any SSH repair flow.
- If port 22 refuses connections, setup treats that as proof that the guest network is reachable. It does not describe the VM as stopped, start UTM, or rediscover IPs. Instead, setup prompts the user to enable Remote Login inside the guest before retrying only the SSH readiness stage.
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
- ClawBox therefore prefers `utmctl ip-address` when it returns usable data, excludes clearly identifiable host-side addresses where safe, and otherwise keeps the existing bounded subnet-based recovery flow as the fallback. Exclusion uses configured `HOST_IP` when available and local host interface addresses so the Mac's own shared-network address is not presented as a guest candidate.

If macOS reports Automation error `-1743`, System Settings may not immediately show an Automation entry. Open UTM normally, run the printed AppleScript verification command from the same terminal application, then check **System Settings > Privacy & Security > Automation**. Quit and reopen the terminal application after granting access. Manual VM startup remains supported even if Automation cannot be granted.

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
