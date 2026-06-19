# VM Lib Guide

## Purpose

VM runtime detection, UTM startup assistance, SSH readiness classification, and
repair/onboarding flows.

## Ownership

- `vm-state.sh`: VM runtime/network/SSH state detection.
- `vm-start.sh`: UTM startup attempts, Automation/TCC handling, and manual-start
  recovery.
- `vm-ssh.sh`: SSH readiness and host-key/auth classification.
- `vm-repair.sh`: user-facing recovery flows after VM/SSH readiness failures.

## Local Contracts

- UTM automatic startup depends on macOS Automation permissions. ClawBox cannot
  bypass TCC.
- `open path/to/vm.utm` can foreground/select/import a VM package, but it is not
  proof that the VM started.
- When Automation is blocked, provide manual-start guidance and verify the VM is
  running or booting before continuing.
- SSH host-key onboarding must distinguish first-contact trust from stale or
  changed host keys.
- Do not add infinite or open-ended VM/network/SSH waits.

## Work Guidance

- Keep failure output diagnostic enough to identify VM name, VM path, start
  method, SSH target, and classification.
- Preserve manual fallback paths for fresh-account onboarding.
- Be conservative around macOS account/session differences; UTM state can be
  user-specific.

## Verification

```bash
bash tests/vm-state-test.sh
bash tests/vm-detection-test.sh
bash tests/output-normalization-test.sh
```

## Child DOX Index

No child AGENTS.md files under `lib/vm/`.
