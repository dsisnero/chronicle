# Sandbox (trial isolation)

Subprocess fork-trial isolation (CONTRACT v1.8 #1). A trial runs
candidate pack code against a **fork** of a saved run inside a
**fresh-interpreter child**, materialized from artifacts pinned by a
bundle hash — so the parent process stays out of the blast radius of a
runaway (memory/CPU) or corrupt in-process state, and the bytes trialed
are the bytes a proposal recorded.

CONTRACT v1.8 #9–#12 also exposes this default behind `TrialExecutor`.
Executors accept a versioned JSON `TrialSpecification` and return a
provider-neutral `TrialResult`; `TrialResult#to_report` returns the
legacy `TrialReport` shape. This is an adapter boundary, not a new
security claim.

!!! note "Import path"
    The sandbox surface lives under `Chronicle::Sandbox` in
    `src/chronicle/sandbox.cr`.

!!! warning "Crash/state isolation, not a security sandbox"
    A fresh interpreter stops runaway memory/CPU and parent-state
    corruption. It does **not** confine syscalls, the network, or
    filesystem access — that is host territory (containers, seccomp).
    The env allow-list is closed (`PATH`/`HOME`/`LANG` plus an explicit
    `env_passthrough`); the child's `CRYSTAL_PATH` is a computed
    code-location channel. The memory cap (`max_rss_bytes`) is announced
    as a warning (never silently claimed) on hosts without an enforced
    rlimit adapter; the wall-clock kill and event budget remain the
    active nets.

## Running a trial

The platform-edge adapter is
`Chronicle::Sandbox::LocalSubprocessTrialExecutor`:

```crystal
executor = Chronicle::Sandbox::LocalSubprocessTrialExecutor.new
warnings = executor.preflight(spec.limits)          # validates the Crystal toolchain
result = executor.execute(spec.to_json)             # validates + runs one trial
```

The chosen Crystal source-pack ABI: the pinned candidate directory
contains `entrypoint.cr` exposing
`Chronicle::Sandbox::CandidatePack::PACK`; an optional scenario names a
Crystal file relative to that directory exposing
`Chronicle::Sandbox::Scenario.run(rt)`. The parent verifies the bundle
hash before compiling a generated child runner, forks the SQLite run
before execution, and the child loads the fixed `PACK` in a fresh
process.

> Divergence: upstream exposes module-level `run_forked_trial` and
> `preflight`. Chronicle folds the run into
> `LocalSubprocessTrialExecutor#execute` (the fork-trial helper is
> private) and keeps `preflight` public on the executor. See
> [`plans/parity.md`](../../../plans/parity.md).

## Executor interface

### `Chronicle::Sandbox::TrialExecutor`

```crystal
abstract class TrialExecutor
  abstract def isolation_guarantees : TrialIsolationGuarantees
  abstract def execute(serialized_specification : String) : TrialResult
end
```

### `Chronicle::Sandbox::TrialSpecification`

`store_path`, `parent_run_id`, `at_event`, `pack_source`, `scenario`,
`limits`, `label`, `extra_packs`, `schema_version` (1). `#to_json` emits
canonical versioned JSON; `.from_json` validates it.

### `Chronicle::Sandbox::TrialResult`

`status`, `budget_use`, `artifacts`, `event_log`, `failure`, `isolation`,
`detail`, `exit_code`, `warnings`. `.from_report(report,
specification:, isolation:, artifacts:)` lifts the legacy report;
`#to_report` is lossless.

### Supporting types

| Type | Fields |
| --- | --- |
| `TrialBudgetUse` | `events_appended`, `behavior_failures`, `limits` |
| `TrialArtifactReference` | `name`, `uri`, `media_type?`, `digest?` |
| `TrialEventLogReference` | `store_path`, `run_id` |
| `TrialFailureDetails` | `kind`, `message`, `exit_code?` |
| `TrialIsolationGuarantees` | `process`, `filesystem`, `network`, `syscalls`, `environment`, `security_sandbox?`, `notes` |

`LOCAL_SUBPROCESS_ISOLATION` is the default local-subprocess posture
(crash and parent-state isolation only, no security sandbox).

### `Chronicle::Sandbox::RecordingTrialExecutor`

Deterministic double: validates each serialized specification, records
it (parsed + raw), and returns the next fixture result. Raises
`RuntimeError` when fixtures are exhausted.

Reusable adapter tests live at
`spec/chronicle/trial_executor_conformance.cr`
(`TrialExecutorConformance.define_tests`).

## Startup preflight

`LocalSubprocessTrialExecutor#preflight(limits = TrialLimits.new)` runs
`crystal --version` and returns warnings (e.g. an unenforced
`max_rss_bytes`). It raises `RuntimeError` when the toolchain is
unavailable.

> Divergence: upstream's `SandboxStartupError` is not ported; the
> adapter raises `RuntimeError`/`ArgumentError` at the edge. See
> [`plans/parity.md`](../../../plans/parity.md).

## Inputs

### `Chronicle::Sandbox::PackSource`

`root_dir`, `expected_bundle_hash`, `manifest_required?`.

### `Chronicle::Sandbox::TrialLimits`

`wall_clock_seconds` (default `120.0`), `max_rss_bytes`, `max_events`
(default `2000`), `max_llm_calls` (default `0` — key-freedom is
structural), `env_passthrough`.

## Result

### `Chronicle::Sandbox::TrialReport`

`outcome`, `fork_run_id`, `events_appended`, `behavior_failures`,
`detail`, `exit_code?`, `warnings`.

### `Chronicle::Sandbox::TRIAL_OUTCOMES`

The closed five-outcome set: `completed`, `scenario_failed`,
`limits_exceeded`, `materialization_failed`, `crashed`.
