# VM Provisioning

Provisioning prepares the VM to run OpenClaw.

Provisioning is intentionally separate from runtime execution.

Provisioning installs and configures dependencies required by OpenClaw, while runtime execution is responsible only for running OpenClaw and related services.

---

# Responsibilities

Provisioning may perform tasks such as:

- installing Homebrew
- installing Node.js
- installing OpenClaw
- validating required runtime dependencies
- preparing runtime directories

Provisioning is the only phase that installs VM-side software.

Runtime execution must not install software.

---

# Provisioning Script

The authoritative provisioning mechanism is:

```text
vm/vm-provision.sh
```

This script is intended to be executed inside the VM.

---

# Host Handoff

ClawBox setup assists provisioning by copying `vm-provision.sh` to the VM
runtime path and printing the exact VM-local commands to run.

The host setup flow does not run `vm-provision.sh` remotely. Provisioning remains
manual and VM-local so installation activity is visible in the VM session.

---

# Current Provisioning Flow

Typical flow:

1. Host setup validates connectivity.
2. Host setup transfers required runtime artifacts.
3. Host setup verifies whether OpenClaw is available.
4. If provisioning is required:
   - VM-local provisioning instructions are presented
   - setup prompts `Provisioning completed inside the VM? [Y/n]:`
5. The user runs `./vm-provision.sh` inside the VM.
6. If the user confirms provisioning completed, host setup refreshes OpenClaw
   runtime state. After OpenClaw is detected, setup offers to run the
   interactive onboarding command over SSH:

   ```bash
   ssh -t vm-user@vm-ip 'zsh -lc "openclaw onboard"'
   ```

   Onboarding runs only after the user confirms. If declined, setup prints the
   exact command using the configured VM SSH target and continues.
7. Setup continues into runtime service setup.
8. If the user declines provisioning completion, setup exits gracefully and prints the resume command:
   `./clawbox setup`.

Provisioning remains a distinct phase separate from runtime execution.

---

# Verification

Provisioning is considered successful when:

- OpenClaw is installed
- OpenClaw is available in PATH
- required dependencies are present
- runtime validation succeeds

Provisioning failures must be corrected before runtime deployment continues.
