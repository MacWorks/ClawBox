# ClawBox Agent Guide

## Purpose

This is the root DOX rail for ClawBox. It defines project-wide contracts and the
Child DOX Index for durable subtrees.

ClawBox is a Bash-based host/VM setup and runtime assistant.

The host side owns interactive setup orchestration, `.env` creation and
preservation, host `llama-server`, UTM VM startup assistance, SSH onboarding,
OpenClaw config generation/deployment, and status reporting.

The VM side owns VM-local provisioning, OpenClaw installation, `openclaw gateway`
execution, and VM user launchd service state.

## Ownership

- Root owns project-wide architecture, generated-artifact policy, and validation
  expectations.
- Child AGENTS.md files own local contracts for their subtree.
- Nearest applicable AGENTS.md controls local work details. Parent docs still
  apply and child docs must not weaken root contracts.

## Local Contracts

- `scripts/setup.sh` should stay orchestration-focused. Implementation details
  belong in focused `lib/` modules.
- Prefer extraction/refactoring over redesign. Preserve behavior unless the user
  has asked for a production fix.
- Tests are authoritative.
- CI-safe tests must not depend on the developer's `.env`, installed local
  software outside normal shell dependencies, real UTM VMs, real SSH access,
  real launchd state, or persistent machine state.
- Do not commit local generated state:
  - `.env`
  - `.env.bak`
  - `.env.*.bak`
  - `.clawbox/`
  - literal `~/`
  - `vm/runtime/openclaw.json`
  - generated files under `logs/`
- Keep `.env.example` and `logs/**/.gitkeep` tracked.

## Work Guidance

- Before editing, read this file and every AGENTS.md along the path to the file
  being changed.
- Keep changes targeted and avoid opportunistic cleanup.
- Use existing Bash patterns and helper APIs.
- Prefer `rg` for search.
- Preserve macOS/Bash compatibility used by the current test suite.
- Do not weaken tests to make local machine state pass.
- Update the nearest owning AGENTS.md when changing durable module ownership,
  runner contracts, setup/status semantics, generated artifacts, or workflow
  rules.

## Verification

After setup/status/runtime changes, run the narrow affected suite first, then:

```bash
bash tests/run-ci-tests.sh
bash tests/run-release-tests.sh
bash tests/run-all-tests.sh
```

Run `bash tests/run-workstation-tests.sh` only when validating a configured
local machine. A workstation-test failure caused by an intentionally incomplete
local `.env` is not a CI regression.

For syntax-sensitive setup/status edits, also run:

```bash
bash -n scripts/setup.sh
bash -n scripts/status.sh
```

## Git Workflow (Mandatory)

This repository uses Git and GitHub as the system of record.

Before making changes:

- Verify repository state:
  - `git status`
  - `git branch --show-current`
  - `git remote -v`

Branching:

- Do not perform development work directly on `main`.
- Create a feature branch for non-trivial work.
- Use descriptive branch names such as:
  - `feature/ternary-bonsai-support`
  - `fix/runtime-health-check`
  - `docs/readme-improvements`

Commits:

- Do not create commits unless explicitly requested.
- Do not amend commits unless explicitly requested.
- Do not create tags unless explicitly requested.
- Do not push to GitHub unless explicitly requested.

Reporting:

Before completing a task, report:

- current branch
- files modified
- tests executed
- test results
- git status summary
- recommended commit message

Repository Hygiene:

- Keep the working tree clean.
- Do not commit generated files, logs, local configuration, editor settings, secrets, or environment-specific artifacts.
- Respect `.gitignore`.
- If a change requires updates to documentation or tests, include them in the same branch.

Safety:

- Never delete branches without explicit approval.
- Never rewrite published history without explicit approval.
- Never force-push without explicit approval.

## Child DOX Index

- `scripts/AGENTS.md`: executable CLI entrypoints and top-level orchestration.
- `lib/AGENTS.md`: shared Bash implementation modules and setup/runtime helpers.
- `lib/vm/AGENTS.md`: VM runtime, startup, SSH readiness, and repair helpers.
- `lib/llama/AGENTS.md`: host LLaMA install/runtime/health helpers.
- `tests/AGENTS.md`: test suites, runners, fixtures, and CI/workstation split.
- `host/AGENTS.md`: host-side scripts and firewall/runtime support artifacts.
- `vm/AGENTS.md`: VM-local provisioning and generated runtime config boundary.
- `docs/AGENTS.md`: durable documentation and contract docs.
