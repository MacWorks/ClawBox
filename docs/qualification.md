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
./clawbox qualify --profile fast
./clawbox qualify --profile full
./clawbox qualify --profile fast --scenario 01-tool-reliability
./clawbox qualify --scenario 01-tool-reliability
./clawbox qualify --json
./clawbox qualify history
./clawbox qualify compare
./clawbox qualify report --latest
./clawbox qualify badge --latest
./clawbox qualify --help
```

`./clawbox qualify` with no `--profile` uses the `full` profile for backward
compatibility. `--profile full` is the complete qualification suite:

- `01-tool-reliability`: 10 iterations
- `02-tool-workflows`: all five workflow cases (`exact-output`,
  `grounded-read`, `absence-check`, `two-step`, and `transform`)
- `03-code-repair`: full code-repair scenario

`--profile fast` is reduced coverage intended for quicker post-switch
validation:

- `01-tool-reliability`: 3 iterations
- `02-tool-workflows`: `exact-output`, `grounded-read`, and `absence-check`
- `03-code-repair`: full code-repair scenario

Fast keeps high-signal coverage for repeated tool use, exact-output discipline,
grounded reading, hallucination restraint, code repair, scope preservation, and
final test verification, but it is not a full qualification. Reports and JSON
include the selected profile and coverage counts. Scores from Fast and Full
should not be compared without considering the different evidence coverage.

When `--scenario <id>` is supplied, ClawBox runs only that scenario using the
selected profile’s parameters. Without `--profile`, selected scenarios use Full
parameters. For example, `--profile fast --scenario 01-tool-reliability` runs
three reliability iterations, while `--scenario 01-tool-reliability` runs ten.

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

Qualification execution progress is evidence-based rather than time-based.
The VM runner emits a progress event only after a scenario unit reaches a
terminal state (`PASS`, `WARNING`, `FAIL`, or `ERROR`). Failed units still count
as completed work. The source of truth is an internal stderr event format used
between the VM runner and host command; it is not a public API.

Profile progress units are:

- Fast: 7 units total
  - 3 tool-reliability iterations
  - 3 workflow cases
  - 1 code-repair scenario
- Full: 16 units total
  - 10 tool-reliability iterations
  - 5 workflow cases
  - 1 code-repair scenario

When a single scenario is selected, the progress total is scoped to that
scenario and profile. For redirected logs and JSON mode, progress is
line-oriented on stderr, for example `Qualification progress: 4/7 — ...`.

## What it measures

Scenario results use these statuses:

- `PASS`: intended behavior and objective state checks succeeded
- `WARNING`: task succeeded with noncritical deviations
- `FAIL`: objective or critical behavioral requirement failed
- `SKIPPED`: scenario was intentionally not run or a declared capability was unavailable
- `ERROR`: qualification infrastructure, executor, dependency, filesystem, or
  evidence collection malfunctioned

Extra tool calls are not automatically failures. They should be warnings when
the final answer and objective state are correct and no prohibited action
occurred. They become failures when they violate explicit instructions,
modify forbidden state, bypass required evidence, or cause the task to fail.
When a prompt explicitly requires tool use, omitting that required tool use is
a failure, even if the final text happens to match a predictable answer.
Additional verification calls are normally warnings when the required state,
grounding, and final answer remain correct.

Tool-reliability and workflow cases score related evidence independently:
agent completion, required tool invocation, tool-count efficiency,
filesystem/state correctness, final-response compliance, and grounding. Exact
output requirements remain exact. For example, replying `Done.` when the prompt
requires `DONE` fails final-response compliance and instruction following, but
does not erase evidence that the model used the tool correctly or produced the
right filesystem state. Human reports summarize expected versus actual
responses for these exact-response failures; full values remain in JSON and
artifacts.

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

When OpenClaw provides structured error evidence, the suite records the error
type, message, timeout flag, and command exit status in the scenario result. A
model that fails to complete within a scenario timeout is treated as a model
`FAIL` with timeout evidence when the surrounding executor and evidence are
otherwise usable. Gateway, dependency, malformed transcript, missing trajectory,
or executor-start failures are infrastructure `ERROR` results.

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
Scores are intentionally auditable: severe objective failures such as missing
required tool use or incorrect filesystem state are weighted more heavily than
response-format-only failures, and efficiency is low-weight so extra calls do
not dominate correctness.

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
provisioning installs or updates it under the OpenClaw workspace. Replaceable
runtime code and persistent run artifacts are separated:

```text
~/.openclaw/workspace/.clawbox/qualification/
├── current/  # installed runner, helpers, scenarios, manifest
└── runs/     # retained run artifacts
```

`./clawbox qualify` also self-heals this installation. It compares a deterministic
suite checksum and version manifest, republishes stale or missing files, and
then runs the VM-side runner from `current/`. Updates replace only `current/`;
they preserve existing `runs/` directories from earlier layouts and newer runs.

After a successful interactive `./clawbox model primary` switch, ClawBox offers
a Fast/Full/Skip qualification menu for the newly running model:

```text
Choose qualification:
  1) Fast (reduced test set)
  2) Full (complete suite)
  3) Skip
Selection [1-3, default 3]:
```

The default is Skip, and declining leaves the completed model switch active.
Noninteractive model switches do not prompt. If qualification is accepted, its
normal result and exit status are preserved; a qualification failure does not
roll back the selected model.

Run artifacts are isolated by run ID:

```text
~/.openclaw/workspace/.clawbox/qualification/runs/<run-id>/
```

Run IDs include the UTC start timestamp plus a suffix, for example
`20260715T130352Z-27276`. Previous run directories are retained; a new
qualification run does not overwrite older artifacts, and suite publication or
installation does not delete historical runs. When comparing reports or
inspecting files manually, compare the `runId` in the aggregate JSON and human
report. Aggregate JSON also records UTC `startedAt` and `completedAt`
timestamps, duration, suite checksum, and available ClawBox Git provenance.
Runner diagnostics are kept under each run's `results/` directory, including
per-scenario result JSON, per-scenario stderr, aggregate input lists, scenario
process statuses, and `aggregate-build.stderr` when aggregate construction
fails.

The suite is limited to ClawBox-managed hidden workspace paths. It does not
replace `~/.openclaw/openclaw.json`, rerun onboarding, switch models, or install
host inference software inside the VM.

## Host-side history index

VM run directories remain the authoritative detailed evidence. ClawBox also
maintains a compact host-side summary index for fast history display,
model-to-model comparison, model-menu annotations, report export, and badges:

```text
data/qualification/
├── runs/
│   └── <run-id>.json
└── models.json
```

`data/qualification/` is runtime data and is ignored by Git except for a
`.gitkeep` placeholder. Each run summary is written atomically as a separate
JSON file, which reduces the chance that an interrupted write can corrupt the
whole history. `models.json` stores automatically maintained model summaries
and optional user metadata. ClawBox uses a lightweight lock directory while
updating these files. If indexing fails after a qualification run, the
qualification result is still returned normally and ClawBox prints a warning.

Run summaries are normalized from aggregate JSON. They include run ID, model
identity, profile, result, score, coverage, warnings, failures, duration,
artifact directory, suite checksum, and available ClawBox Git provenance.
Absolute paths may appear in JSON summaries so that artifacts can be traced, but
human output generally shows model basenames or display names.

### History

```bash
./clawbox qualify history
./clawbox qualify history --json
./clawbox qualify history --model Ternary-Bonsai-27B-Q2_g64.gguf
./clawbox qualify history --profile full --limit 5
./clawbox qualify history --latest
./clawbox qualify history --refresh
```

History is sorted newest first. Viewing a historical `FAIL` exits `0` because
the history command succeeded; the model result is historical data, not the
command's own failure.

`--refresh` backfills the host index from retained VM aggregate files under the
qualification `runs/` directory. It imports valid completed runs, deduplicates
by `runId`, skips malformed or incomplete runs with warnings, and never deletes
VM artifacts.

### Comparison

```bash
./clawbox qualify compare
./clawbox qualify compare --models model-a.gguf,model-b.gguf
./clawbox qualify compare --run <run-id> --run <run-id>
./clawbox qualify compare --profile fast
./clawbox qualify compare --json
```

By default, comparison uses the most recent completed Full run for each model.
Model/profile comparisons use like-for-like profiles. Explicit `--run` values
may compare any selected runs. The report displays only metrics present in the
indexed records and does not declare an absolute winner.

### Model metadata

Optional user metadata is maintained with:

```bash
./clawbox model metadata <model>
./clawbox model metadata <model> --set-display-name "Ternary Bonsai 27B"
./clawbox model metadata <model> --add-role coding
./clawbox model metadata <model> --set-note "Preferred for interactive use"
./clawbox model metadata <model> --preferred
./clawbox model metadata <model> --json
```

Automatic metadata includes basename, canonical path when known, last qualified
run, latest Fast and Full results, latest score and duration, recent ClawBox
commit, suite checksum, and indexed run count. User-maintained display names,
roles, notes, and preferred flags are preserved when automatic summaries are
rebuilt.

When qualification data exists, `./clawbox model primary` annotates available
GGUF files with a compact latest Full result. Missing or corrupt metadata never
blocks model switching.

### Markdown report export

```bash
./clawbox qualify report --latest
./clawbox qualify report --run <run-id>
./clawbox qualify report --latest --format markdown
./clawbox qualify report --run <run-id> --output /tmp/report.md
```

Markdown is the initial export format. Without `--output`, the report is printed
to stdout. With `--output`, ClawBox writes atomically and refuses to overwrite
an existing file unless `--force` is supplied. Markdown output escapes table
characters and omits full transcripts or large raw diffs by default.

### Badges

```bash
./clawbox qualify badge --latest
./clawbox qualify badge --model <model>
./clawbox qualify badge --run <run-id>
./clawbox qualify badge --format text
./clawbox qualify badge --format markdown
./clawbox qualify badge --format json
```

Text badges use neutral wording such as `CLAWBOX QUALIFICATION · Full · PASS ·
100/100 · model.gguf`; `QUALIFIED` is not used to imply that a failing model
passed. Markdown badges emit a shields.io-compatible URL string without network
access. JSON badges include the selected run ID, model, profile, status, score,
label, message, color, and Markdown string.

Status colors are deterministic:

- `PASS`: `brightgreen`
- `WARNING`: `yellow`
- `FAIL`: `red`
- `ERROR` or unrated: `lightgrey`

### Performance metrics

The initial host index records duration and model file size when the model path
is known and readable. More detailed runtime metrics are represented as
unavailable with a limitation note unless they are present in aggregate data.
ClawBox does not use invasive privileged tools, does not promise GPU/VRAM
metrics on macOS, and never fails correctness qualification because performance
metadata is missing.

Historical comparisons tolerate older runs without metrics.

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

- `./clawbox qualify`: `0` when qualification completed with no `FAIL` or
  `ERROR`, `1` for model qualification failures, and `2` for qualification
  infrastructure or configuration errors.
- Read-only history, compare, report, badge, and metadata commands: `0` when
  the command operation succeeds, `1` for invalid user requests or unavailable
  requested records, and `2` for infrastructure or index corruption errors.

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
- Host-side performance metrics are intentionally conservative in the initial
  history index.
- The production scenarios have not been live-validated until `./clawbox
  qualify` is run from the real ClawBox runtime account.
