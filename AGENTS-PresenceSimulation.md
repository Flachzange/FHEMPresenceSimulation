# AGENTS-PresenceSimulation.md — PresenceSimulation project rules

**Mandatory companion to [`AGENTS.md`](AGENTS.md).** For every task involving this repository, read and apply both files. This supplement defines PresenceSimulation-specific behavior and requirements; reusable FHEM engineering rules remain in `AGENTS.md`.

This repository contains the FHEM module `PresenceSimulation`.

## Source of truth

- The only authoritative module source is `98_PresenceSimulation.pm` in the repository root.
- Project release artifacts belong in `dist/`; the generic source-of-truth and build-output rules in `AGENTS.md` apply.

## Project identity

- Module type: `PresenceSimulation`
- File: `98_PresenceSimulation.pm`
- Initialize callback: `PresenceSimulation_Initialize`
- Global subroutines use the `PresenceSimulation_` prefix.
- License: GPL-2.0-or-later
- Author display name: `Flachzange`
- Release status: testing / experimental
- Current persistence schema: 3
- No legacy or migration support is intended.

## Product behavior

PresenceSimulation learns completed on/off sessions of generic configured devices,
uses live events and/or DbLog history, builds a time-dependent probability model,
and supports dry-run and real playback. It must remain generic; do not introduce
light-specific names or behavior.

The module distinguishes:

- `device`: logical model key and command target
- optional `readingDevice`: observation source for live state, feedback, manual
  intervention detection, restart reconciliation, and DbLog history

If `readingDevice` is omitted it defaults to `device`.

## Playback safety and interface contracts

- Numbered attributes must remain regex-defined in `AttrList`.
- Unknown device states must never be treated as `off`.
- Playback may manage only devices it switched on itself.
- Manual changes must not be overwritten silently.
- Stop, undef, reload, and shutdown paths must try to leave managed devices safe.
- Dangerous configuration changes during active or unresolved playback must remain blocked.
- Block conditions must be parsed by the controlled parser; never evaluate arbitrary Perl.
- `eventFn` remains a generic FHEM command template with only these placeholders:
  `$NAME`, `$MODE`, `$DEVICE`, `$ACTION`, `$EVENT`, `$EVENTDETAILS`.
- Do not add `%` placeholders, `fn:`/`cmd:` syntaxes, implicit function calls, or
  module-specific `msg` handling.

## Defaults and public state

- Default mode is `off`.
- At least one valid `deviceNN` is required before training, dry-run, playback, or DbLog import.
- Error readings are `lastError`, `lastErrorSource`, and `lastErrorTime`; their
  no-error value is `none`.
- Keep the number of public readings minimal. Do not add diagnostic readings when
  the existing error readings or an internal persisted field are sufficient.
- The internal FHEMWEB `devStateIcon` default must remain overridable by a normal attribute.

## Persistence

Files are:

- `PresenceSimulation_Raw_<device-name>.json`
- `PresenceSimulation_State_<device-name>.json`

Requirements:

- schema 3 unless a deliberate future schema change is approved
- no automatic schema migration
- no `AnwSim_` legacy prefix support
- atomic writes
- permissions `0600`
- backups
- complete semantic validation
- recovery only from a semantically valid backup
- damaged main files preserved as `.corrupt.<timestamp>`
- no persistent model file; rebuild the model from raw data

Optional new fields may be added to schema-3 runtime structures only when old
schema-3 files remain valid and tests prove compatibility.

## Probability model

Current model rules:

- one probability decision per device and time block
- failed decisions consume the block
- successful decisions persist a plan
- start positions are sampled from historical positions within the block
- durations are sampled from block history with a device-wide fallback
- `probabilityFactor` is captured when a plan is created
- a blocked due plan emits exactly one pending `action=blocked` event and may retry
  within the same block
- if later released, waiting time is subtracted from duration to preserve the
  original planned end time
- if less than one full minute remains, do not switch on

A later larger model is tracked in [issue #2](https://github.com/Flachzange/FHEMPresenceSimulation/issues/2).
It is planned around daily session-count sampling, smoothed start-time distributions,
time-dependent durations, collision prevention, and hierarchical weekday smoothing.
Do not implement that architecture as an incidental small change.

## Tests and release completeness

Every behavior change must update all relevant artifacts (version changes apply to
approved release changes, not analysis-only, docs-only or tests-only work):

- module source
- English commandref
- German commandref
- version and embedded META
- changelog
- tests
- README / testing notes where relevant

Run at minimum:

```bash
scripts/ci.sh
```

Before publishing a release run:

```bash
scripts/build-release.sh
```

The release process must verify:

- Perl syntax
- the complete self-test suite
- embedded META JSON and CPAN::Meta validation
- English and German commandref blocks
- callback names
- duplicate global subroutines
- persistence schema
- absence of legacy paths
- MANIFEST
- internal SHA-256 sums
- ZIP integrity
- byte equality of root, versioned, current, and ZIP module copies

Do not claim that self-tests replace real integration tests. Every release summary
must explicitly state which real FHEM, DbLog, device, playback, shutdown, reload,
and manual-intervention tests were not performed.

## Project release versioning

- Follow the generic branch and draft-PR workflow in `AGENTS.md`.
- Do not bump the version for analysis-only, docs-only or tests-only tasks.
- For an approved release change, bump the version consistently in code, META,
  changelog, README/testing references, and tests.
