# Firewall

Firewall management is not part of the supported `./clawbox setup` release path.

## Current state

- setup no longer prompts for firewall modes or subnet policy
- setup does not invoke `host/firewall/apply.sh`
- ClawBox does not automatically apply macOS `pf` rules during setup

## Remaining configuration

`FIREWALL_SHARED_SUBNET` remains in `.env` with its legacy name because VM SSH recovery and VM IP discovery still use it as a shared-network hint.

Relevant code paths:

- `lib/vm/vm-ssh.sh` derives the shared subnet from `FIREWALL_SHARED_SUBNET` when present
- `scripts/setup.sh` persists `FIREWALL_SHARED_SUBNET` from the configured VM IP without exposing a firewall setup section

## Legacy manual helper

The repository still contains a manual helper at `host/firewall/apply.sh` plus the template at `host/firewall/pf.conf.fragment`.

That helper is not invoked by setup, is not required for normal ClawBox operation, and is not treated as a supported first-release feature.

## Related docs

- `docs/setup/host.md`
- `docs/setup/vm.md`
