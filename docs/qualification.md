# Model Qualification

`./clawbox qualify` runs a VM-side qualification suite against the currently
configured OpenClaw model. ClawBox reports both the stable OpenClaw alias
(usually `clawbox/local`) and the configured/running host GGUF identity so that
the alias is not mistaken for the actual model under test. It is intended to
measure practical agent-readiness for ClawBox/OpenClaw workflows rather than raw
benchmark intelligence.

The suite currently ports the original VM prototype scenarios into a structured
runner with deterministic objective checks for these scenario areas:

- tool-calling reliability
- multi-step tool workflow behavior
- code repair and state verification

The original prototype scripts are retained under
`prototype/model-qualification/` as reviewable source references. They are not
installed into the VM payload. The production suite lives under
`vm/qualification/` and adapts those prototypes to isolated run directories,
structured results, aggregate reporting, and automatic VM publication.

## Usage

```bash
./clawbox qualify
./clawbox qualify --scenario 01-tool-reliability
./clawbox qualify --json
./clawbox qualify --help
```

`--json` writes only the aggregate JSON document to stdout. Progress and
diagnostics are written to stderr. The aggregate `model` field is an object with
`alias`, `configured`, and `running` values.

Before publishing or running scenarios, ClawBox verifies that the configured
host model from `.env` matches the model currently reported by the host
`llama-server` API. A mismatch is treated as an infrastructure/configuration
error and exits `2`; qualification never switches models, restarts
`llama-server`, or attempts an interactive repair.

Human-readable runs show ClawBox-style progress for host inference, VM SSH,
OpenClaw availability, model consistency, suite publication, installation, and
the long-running scenario/suite execution. In JSON mode, stdout remains JSON
only while progress stays on stderr.

## What it measures

Scenario results use these statuses:

- `PASS`: intended behavior and objective state checks succeeded
- `WARNING`: task succeeded with noncritical deviations
- `FAIL`: objective or critical behavioral requirement failed
- `SKIPPED`: scenario was intentionally not run or a declared capability was unavailable
- `ERROR`: qualification infrastructure malfunctioned or timed out

Extra tool calls are not automatically failures. They should be warnings when
the final answer and objective state are correct and no prohibited action
occurred. They become failures when they violate explicit instructions,
modify forbidden state, bypass required evidence, or cause the task to fail.

The production scenarios invoke OpenClaw with the demonstrated prototype
contract:

```bash
openclaw agent \
  --session-id "$session" \
  --timeout <seconds> \
  --json \
  --message "$prompt"
```

The runner records the `openclaw agent` process exit status separately from the
trajectory `finalStatus` and the scenario assertion outcome. A nonzero process
exit can still produce a warning rather than a failure when usable evidence
shows the objective task succeeded.

Evidence is read from the OpenClaw session directory:

```text
$HOME/.openclaw/agents/main/sessions/
```

The suite expects trajectory records containing `trace.artifacts` with
`data.finalStatus` and `data.toolMetas`, plus the corresponding transcript
JSONL for the final assistant reply. This evidence format is OpenClaw-version
sensitive. Missing trajectories, multiple matching trajectories, missing
transcripts, malformed JSONL, or missing required fields are infrastructure
`ERROR` results, not ordinary model failures.

## Scoring

The aggregate JSON schema starts at version `1`. A numeric score is emitted only
when enough rated evidence exists. Unsupported categories remain unrated rather
than being invented from missing evidence. Critical failures remain visible and
can determine the overall result even when other categories are healthy.

Initial categories are:

- Tool correctness
- Grounding
- Workflow correctness
- Instruction following
- Code and state correctness
- Hallucination avoidance
- Efficiency

## Installation and artifacts

The source suite lives in the repository at:

```text
vm/qualification/
```

Setup publishes it next to `vm-provision.sh` in `VM_RUNTIME_PATH`. VM
provisioning installs or updates it under the OpenClaw workspace:

```text
~/.openclaw/workspace/.clawbox/qualification/
```

`./clawbox qualify` also self-heals this installation. It compares a deterministic
suite checksum and version manifest, republishes stale or missing files, and
then runs the VM-side runner.

After a successful interactive `./clawbox model primary` switch, ClawBox offers
to run the normal qualification suite against the newly running model. The
prompt defaults to No, and declining leaves the completed model switch active.
Noninteractive model switches do not prompt. If qualification is accepted, its
normal result and exit status are preserved; a qualification failure does not
roll back the selected model.

Run artifacts are isolated by run ID:

```text
~/.openclaw/workspace/.clawbox/qualification/runs/<run-id>/
```

Run IDs include the UTC start timestamp plus a suffix, for example
`20260715T130352Z-27276`. Previous run directories are retained; a new
qualification run does not overwrite older artifacts. When comparing reports or
inspecting files manually, compare the `runId` in the aggregate JSON and human
report. Aggregate JSON also records UTC `startedAt` and `completedAt`
timestamps, duration, suite checksum, and available ClawBox Git provenance.

The suite is limited to ClawBox-managed hidden workspace paths. It does not
replace `~/.openclaw/openclaw.json`, rerun onboarding, switch models, or install
host inference software inside the VM.

The production payload intentionally excludes:

- `prototype/`
- `tests/`
- test fixtures and mock executors

Only the production runner, helpers, scenarios, and manifest are published.

## VM dependencies

The VM-side runner requires these commands to already be present:

- `bash`
- `jq`
- `git`
- `openclaw`

Qualification does not install these dependencies. Missing dependencies produce
exit status `2` with an infrastructure `ERROR`.

## Exit status

- `0`: qualification completed with no `FAIL` or `ERROR` result
- `1`: one or more model qualification failures
- `2`: qualification infrastructure or configuration error

Warnings alone do not produce exit status `1`.

## Privacy and security

Qualification prompts and artifacts are stored inside the VM workspace under
the ClawBox-managed qualification directory. They may include model responses,
fixture diffs, command output, and scenario logs. Review artifacts before
sharing them.

## Adding a scenario

Add a new executable scenario script under:

```text
vm/qualification/scenarios/
```

Each scenario should separate fixture setup, agent execution, evidence
collection, objective evaluation, and result serialization. It must write a
single JSON result to stdout and keep diagnostic artifacts under its scenario
artifact directory.

Each scenario needs:

- stable ID and descriptive name
- timeout or bounded execution behavior
- isolated working state
- captured stdout/stderr
- objective assertions
- clear warnings and failures
- preserved artifacts sufficient for debugging
- no account-specific workspace paths; use the run/scenario artifact directory
  passed by the runner

## Live validation boundary

Repository tests use controlled fake executors and session fixtures. They do
not contact a real VM, real OpenClaw, or a real model.

Live qualification should be run only from the macOS account that owns the
working ClawBox `.env`, VM SSH access, and OpenClaw runtime. Seeing a host
`llama-server` on port `11434` from another account is not sufficient to make
that account a valid qualification environment.

## Known limitations

- Tool-call counting depends on `trace.artifacts.data.toolMetas`.
- Transcript parsing depends on OpenClaw JSONL assistant message records.
- The first aggregate score is intentionally simple and auditable; unsupported
  evidence should remain unrated rather than inferred.
- The production scenarios have not been live-validated until `./clawbox
  qualify` is run from the real ClawBox runtime account.
