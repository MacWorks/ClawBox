# Architecture Overview

ClawBox separates model inference from agent execution.

The host runs `llama-server` natively for Metal-backed inference. A macOS VM runs OpenClaw in an isolated environment and communicates with the host through an OpenAI-compatible HTTP API.

The public command surface is exposed through:

```text
./clawbox
```

which dispatches setup, status, and related operations.

---

# Core Architecture

ClawBox is intentionally divided into three major layers:

1. Host orchestration
2. VM provisioning
3. Runtime execution

Each layer has distinct responsibilities and ownership.

---

# Host Responsibilities

The host is responsible for:

- storing and validating `.env`
- running `llama-server`
- generating OpenClaw configuration
- managing the authoritative OpenClaw configuration state
- transferring runtime artifacts to the VM through SSH
- validating VM connectivity
- detecting VM runtime state
- managing host-side launchd services
- orchestrating deployment and runtime workflows

The host is the authoritative control plane.

---

# VM Responsibilities

The VM is responsible for:

- running OpenClaw
- executing `vm-provision.sh`
- maintaining required runtime dependencies
- running `openclaw gateway`
- exposing runtime state for host-side inspection
- keeping provisioning separate from runtime execution

The VM is intentionally not responsible for:

- model inference
- host configuration generation
- host service management

---

# Provisioning Model

Provisioning remains a distinct phase.

The host may assist with provisioning, but provisioning activity must remain visible and intentional.

Typical flow:

1. Host validates connectivity.
2. Host deploys required runtime artifacts.
3. Host verifies OpenClaw availability.
4. If provisioning is required, ClawBox presents provisioning instructions or provisioning commands.
5. Provisioning executes.
6. Setup resumes after provisioning succeeds.

Provisioning failures stop the workflow.

---

# Runtime Model

Runtime execution is separate from provisioning.

Runtime responsibilities include:

- OpenClaw execution
- runtime state verification
- configuration synchronization
- launchd management
- inference connectivity validation

Runtime execution must not install software.

Missing dependencies are treated as setup or provisioning problems rather than runtime responsibilities.

---

# Setup Architecture

The setup flow is orchestrated by:

```text
scripts/setup.sh
```

The long-term architectural goal is for setup.sh to remain primarily an orchestration layer.

Reusable implementation logic belongs in:

```text
lib/
```

Current library ownership includes:

```text
lib/config.sh
lib/deploy.sh
lib/launchagent.sh
lib/runtime.sh
lib/ssh.sh
lib/llama.sh
lib/vm/*
```

This separation improves testability and reduces regression risk.

---

# Control Flow

Normal setup execution follows this sequence:

1. Read `.env`.
2. Validate host prerequisites.
3. Validate VM availability.
4. Establish or verify SSH connectivity.
5. Generate OpenClaw configuration.
6. Compare configuration state.
7. Transfer runtime artifacts when needed.
8. Verify OpenClaw installation state.
9. Perform provisioning when required.
10. Manage runtime state according to configuration.
11. Verify final readiness.

Repeated runs should converge safely without duplicating work.

---

# Status Architecture

Status reporting is provided by:

```text
./clawbox status
```

Status is a read-only diagnostic command.

Status checks may:

- inspect configuration
- inspect runtime state
- inspect connectivity
- inspect launchd state
- inspect inference availability

Status checks must not modify system state.

Failures should be reported once per underlying issue and should not be double-counted.

---

# Networking Model

- `llama-server` listens on the host.
- The VM connects through `LLAMA_BASE_URL`.
- SSH is host-initiated and non-interactive after bootstrap.
- VM IP recovery may use configured subnet hints.
- Host-to-VM communication occurs through SSH.
- VM-to-host communication occurs through OpenAI-compatible HTTP APIs.

Firewall management is not part of the supported setup workflow.

The legacy firewall helper remains a manual, standalone utility.

---

# Design Constraints

The system must:

- remain idempotent
- remain safe to re-run
- fail fast on critical errors
- preserve separation between provisioning and runtime
- avoid silent configuration changes
- avoid silent service manipulation
- avoid hidden provisioning activity

---

# Logging Model

Logs are centralized under:

```text
logs/
```

Operational areas include:

```text
logs/runtime/
logs/setup/
logs/tests/
logs/vm/
logs/ssh/
logs/dev/
```

Repository root should remain free of generated log artifacts.

Generated logs should remain gitignored where appropriate.

Shared logging helpers should be preferred over ad hoc logging implementations.

---

# Test Architecture

The repository test suite is the authoritative validation mechanism.

Primary entrypoints are:

```text
bash tests/run-release-tests.sh
bash tests/run-all-tests.sh
make test
```

Release validation focuses on:

- regressions
- VM detection
- VM state management
- setup coverage
- llama ownership behavior

Full validation extends release validation with broader library and setup coverage.

Behavior changes should be accompanied by persistent test coverage whenever practical.

---

# Related Documentation

- `docs/setup/host.md`
- `docs/setup/vm.md`
- `docs/setup/provisioning.md`
- `docs/components/runtime.md`
- `docs/components/llama-server.md`
- `docs/components/firewall.md`
- `docs/contract/clawbox-contract.md`