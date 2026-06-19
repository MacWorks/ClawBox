# Pre-Release Hardening Notes

This document tracks architecture and maintainability concerns discovered while stabilizing ClawBox before release.

These notes are advisory and do not override the ClawBox Contract.

## Current hotspots

- `scripts/setup.sh` still coordinates a large number of concerns in one flow (environment bootstrap, VM readiness, llama ownership and selection, deployment, provisioning orchestration, and runtime management).
- VM onboarding behavior remains distributed across `lib/vm/vm-start.sh`, `lib/vm/vm-repair.sh`, and `lib/vm/vm-ssh.sh`, increasing review complexity.
- SSH classification and recovery decisions remain spread across probing, repair, and onboarding flows.
- Layout and spacing behavior has largely moved into `lib/output.sh`, but some legacy call sites still compose output manually.
- Semantic output styling is mostly centralized, but warning, error, and informational messaging should continue to be reviewed for consistency.
- Network recovery depends on a bounded recovery menu contract and predictable retry behavior.
- Cross-user `llama-server` ownership scenarios remain one of the more complex onboarding paths and require continued regression coverage.
- Provisioning and runtime responsibilities must remain clearly separated even if setup gains additional orchestration capabilities.

## Refactor opportunities

- Extract setup orchestration phases from `scripts/setup.sh` into smaller host-side modules.
- Consolidate VM onboarding into an explicit state-machine model.
- Create a unified SSH onboarding classification contract that separates:
  - transport reachability
  - password-auth state
  - key-auth state
- Continue replacing ad hoc output formatting with shared `lib/output.sh` primitives.
- Reduce coupling between provisioning orchestration, deployment orchestration, and runtime orchestration while preserving explicit user awareness.

## Dead-code and duplication candidates

- Repeated VM connectivity guidance strings and branching patterns in VM repair flows.
- Repeated menu rendering behavior that could be centralized through shared output helpers.
- Duplicate onboarding success or failure messaging.
- Legacy transient test artifacts and obsolete validation scaffolding.

## Test hardening priorities

- Preserve deterministic test entrypoints.
- Prefer reusable test helpers over terminal-only validation logic.
- Continue increasing direct helper coverage for extracted modules.
- Ensure orchestration refactors preserve behavioral coverage before moving functionality out of `scripts/setup.sh`.

## Pre-release hygiene checks

- Keep repository root free of generated `.log` files.
- Reject transient shell artifacts.
- Prefer stable persistent test entrypoints for validation.
- Keep generated runtime and test artifacts inside approved logging locations.