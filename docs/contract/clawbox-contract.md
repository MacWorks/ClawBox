# ClawBox Contract

## Purpose

ClawBox is a deterministic, repeatable system that runs OpenClaw inside a VM using a host-provided model backend.

The system MUST be reproducible, safe to re-run, and may include controlled, idempotent user interaction during setup.

---

## 0. INTERACTIVITY RULES

setup.sh MAY prompt the user for input.

Prompts MUST:

- provide safe defaults where practical
- support sensible re-run behavior
- be transparent
- avoid unnecessary repetition

setup.sh MUST remain idempotent.

setup.sh MUST NOT require repeated manual input on subsequent runs unless required state is missing or invalid.

Provisioning remains the authoritative mechanism for VM setup.

setup.sh MAY assist the user by copying provisioning helpers to the VM runtime
path and printing the exact VM-local commands to run.

setup.sh MUST NOT:

- silently run provisioning
- run provisioning remotely from the host
- hide provisioning activity
- modify provisioning behavior without corresponding provisioning changes

---

## 1. SYSTEM ARCHITECTURE (NON-NEGOTIABLE)

### Host Responsibilities

The host is responsible for:

- running llama.cpp services
- generating OpenClaw configuration
- transferring runtime artifacts to the VM
- orchestrating deployment
- providing setup guidance
- managing host-side inference dependencies

### VM Responsibilities

The VM is responsible for:

- running OpenClaw
- executing provisioning
- hosting runtime artifacts
- running gateway services

The VM MUST NOT:

- perform model inference
- generate host-side configuration

---

## 2. STRICT SEPARATION OF CONCERNS

### Provisioning Layer (VM)

Provisioning is a VM responsibility.

Provisioning MAY be initiated manually inside the VM.

Provisioning MUST:

- remain transparent
- remain visible
- remain fail-fast

Provisioning MUST NOT occur automatically, silently, or remotely from the host.

### Host Setup Layer

Host setup MAY:

- install llama.cpp
- install host-side dependencies
- configure host-side services

Host setup MUST:

- require user approval
- be transparent
- be idempotent

### Runtime Layer

Runtime responsibilities include:

- generating configuration
- transferring artifacts
- validating readiness
- managing runtime state

Host responsibilities and VM responsibilities MUST remain separated.

---

## 3. NO INSTALLS AT RUNTIME

This restriction applies to runtime execution.

### VM Runtime

VM runtime MUST NOT:

- install software
- modify dependency state

VM runtime MUST fail fast when dependencies are missing.

### Host Setup

Host setup MAY install software.

Host setup installs MUST:

- require user approval
- be visible
- be idempotent

Provisioning remains responsible for VM-side software installation.

---

## 4. FAIL-FAST REQUIREMENT

All scripts MUST:

- validate prerequisites
- stop on failure
- report failures clearly

Scripts MUST NOT silently continue after critical failures.

---

## 5. ENVIRONMENT DISCIPLINE

Host configuration originates from .env.

For new setups, the OpenClaw-facing model alias is stable (`clawbox/local` by
default). Changing the host GGUF through `./clawbox model` MUST remain a
host-only operation and MUST NOT replace VM OpenClaw configuration.

Host configuration MUST NOT be consumed directly by VM runtime behavior.

VM runtime MUST rely on transferred artifacts and runtime configuration.

---

## 6. PATH DISCIPLINE

User-specific paths MUST NOT be hardcoded.

Paths MUST be:

- provided through configuration
- derived dynamically
- discovered deterministically

---

## 7. VM RUNTIME CONTRACT

The VM runtime directory contains runtime artifacts such as:

- openclaw.json
- provisioning helpers
- runtime support files

setup.sh MUST NOT:

- silently execute provisioning
- silently restart services
- silently alter user configuration

Any runtime restart or service modification MUST be:

- disclosed
- intentional
- user approved when appropriate

---

## 8. SSH CONTRACT

### Steady-State Requirements

SSH MUST be:

- key-based
- non-interactive

The host initiates all connections.

### Bootstrap Allowance

setup.sh MAY assist the user in establishing SSH access.

Bootstrap actions MAY include:

- generating SSH keys
- copying public keys
- validating connectivity

Bootstrap assistance MUST:

- require user consent
- be visible
- be verifiable
- fail fast

setup.sh MUST NOT:

- assume SSH is configured
- silently alter SSH configuration
- bypass connectivity verification

### Failure Behavior

If SSH cannot be established:

- setup.sh MUST stop progression
- setup.sh MUST provide remediation guidance

---

## 9. IDE INDEPENDENCE

The system MUST NOT depend on IDE-specific tooling.

All functionality MUST remain usable outside any specific editor or IDE.

---

## 10. IDEMPOTENCY

All operations MUST be safe to re-run.

Repeated execution MUST NOT:

- duplicate state
- create conflicting configuration
- corrupt existing configuration

---

## 11. DOCUMENTATION REQUIREMENT

Documentation MUST accurately reflect actual behavior.

Behavior changes MUST update relevant documentation.

Provisioning documentation MUST include:

- exact provisioning steps
- verification steps
- expected outcomes

Documentation MUST NOT knowingly become stale.

---

## 12. VERIFICATION REQUIREMENTS

### Host Verification

Verification MUST confirm:

- configuration generation
- inference availability
- SSH functionality

### VM Verification

Verification MUST confirm:

- OpenClaw installation state
- runtime availability
- gateway readiness

---

## 12.1 RUNTIME STATE DETECTION

The system MUST detect:

- not installed
- installed but not running
- running

Detection MUST:

- be read-only
- avoid state modification
- use SSH where appropriate
- use login-shell semantics where required

---

## 13. TESTING CONTRACT

Behavioral changes MUST include validation.

When practical:

- existing tests MUST be updated
- regressions MUST receive persistent coverage
- validation MUST be reproducible

The repository test suite is the authoritative validation mechanism.

Persistent tests are preferred over terminal-only diagnostics.

When behavior can reasonably be validated through a test:

- prefer adding or updating a test
- avoid relying solely on ad hoc terminal investigation

---

## 14. SETUP ORCHESTRATION CONTRACT

scripts/setup.sh is the orchestration layer.

Business logic SHOULD reside in reusable library modules.

New functionality SHOULD generally be implemented in library modules and coordinated through setup.sh.

setup.sh SHOULD primarily handle:

- orchestration
- flow control
- user interaction
- coordination

rather than subsystem implementation.

This is guidance for project evolution and not a hard architectural restriction.

---

## 15. STATUS CONTRACT

The status command MUST be read-only.

Status checks MUST NOT modify system state.

Status reporting MUST avoid duplicate reporting of the same underlying failure.

Status output SHOULD reflect actual system state as accurately as practical.

Health checks SHOULD distinguish between:

- configuration problems
- connectivity problems
- runtime problems

without double-counting equivalent failures.

---

## 16. TEST ENTRYPOINT CONTRACT

The repository MUST provide stable test entrypoints.

Canonical test runners SHOULD exist for:

- release validation
- full validation

Test execution SHOULD favor:

- persistent test files
- deterministic behavior
- reproducible results

over temporary terminal-only validation logic.

The preferred validation path is:

- run a test entrypoint
- evaluate results
- update tests when behavior changes

rather than repeatedly constructing ad hoc shell diagnostics.
