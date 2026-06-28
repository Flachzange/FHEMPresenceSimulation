# Changelog

## 1.1.10 — 2026-06-28

This release simplifies exhausted playback OFF handling without changing
persistence schema 3.

### Automatic release after failed OFF confirmation

- The existing bounded OFF schedule remains unchanged: immediately, after one
  minute, and after another five minutes, followed by the final confirmation grace
  period.
- If OFF is still not confirmed, PresenceSimulation records the failure through the
  existing `lastError*` readings and the FHEM log, then removes the device from
  managed playback state without claiming that it is physically off.
- `activePlayback` and `stoppingPlayback` no longer remain blocked by an exhausted
  OFF cycle. Playback-sensitive configuration becomes available again as soon as no
  other managed device remains.
- Future ON commands remain guarded by the observed device state and are sent only
  when it is unambiguously classified as `off`.
- Removed the now-unnecessary `retryOff` and `forceReleaseManaged` set commands.
- Existing schema-3 files containing a persisted `offFailed` entry remain valid;
  reconciliation reports the failure and releases the stale managed entry. This is
  an explicitly temporary compatibility exception tracked for removal in issue #9.
- A final playback OFF error remains visible until a later successful playback ON
  action clears it or another error supersedes it.

### Tests

- Updated OFF retry, persistence compatibility, restart reconciliation, readings,
  command-list, and playback safety coverage for automatic release.
- The complete self-test suite now contains 391 checks.

## 1.1.9 — 2026-06-27

This release adds an independent execution switch for the optional `eventFn` handler.
Persistence schema 3 remains unchanged.

### Switchable event handler

- Added the `eventFnEnabled 0|1` attribute with an effective default of `1`.
- Value `0` keeps the complete `eventFn` configuration stored while suppressing only
  handler execution. The `simulationEvent` reading and FHEM event continue unchanged.
- Re-enabling with value `1`, or deleting `eventFnEnabled`, immediately restores the
  existing handler without rewriting it.
- Toggling the attribute does not reinitialize the module, rebuild the model, reset
  timers, or discard pending real or dry-run plans.
- Disabling clears an existing `lastError` only when its source is `eventFn`; errors
  from other subsystems remain untouched.
- `eventFn` remains validated when configured, even while execution is disabled.

### Tests

- Expanded the suite to 378 tests. New checks cover attribute validation,
  backward-compatible defaults, unchanged event publication, dry-run and playback
  execution, plan preservation, absence of reinitialization, and selective error
  clearing.

## 1.1.8 — 2026-06-17

This release corrects the runtime of a pending blocked plan that starts later in its
current time block. Persistence schema 3 remains unchanged.

### Delayed duration

- The wait from the originally planned start to the actual start is subtracted from
  the sampled duration. The originally planned end time is therefore preserved.
- Example: planned 19:25 for 109 minutes, released at 19:28: the ON event reports
  `duration=106min`, `started=19:28`, and `delayed=3min`; the end remains 21:14.
- If less than one full minute remains when the block clears, the plan is consumed
  without switching and without another event. The initial pending blocked event
  remains the only notification.
- Dry-run and real playback use the same calculation.

### Tests

- Expanded the suite to 364 tests. New checks cover reduced dry-run and playback
  durations, preservation of the original end time, and expiry without an ON event
  when no full minute remains.

## 1.1.7 — 2026-06-17

This release keeps a due start plan pending when a global or device-specific block
condition is active. Persistence schema 3 remains unchanged.

### Pending blocked plans

- The first blocked check at the planned start emits exactly one `action=blocked`
  event with `pending=1`, `retryUntil=HH:MM`, and the matching condition name.
- The plan remains persisted and the blocking conditions are checked again on each
  simulation tick until the current time block ends. No new probability draw occurs.
- If the block clears in time, the plan starts and the `action=on` event adds
  `started=HH:MM` and `delayed=Nmin`. The originally sampled duration is retained and
  begins at the actual start time.
- If the block remains active through the boundary, the plan expires without a second
  blocked event.
- The behavior is identical in dry-run and real playback. A persisted
  `blockNotified` marker prevents duplicate notification after save or reload.

### Tests

- Expanded the suite to 353 tests. New checks cover pending block persistence,
  one-time notification, repeated checks, delayed dry-run and playback starts, block
  expiry without a duplicate event, block-boundary formatting, and schema validation.

## 1.1.6 — 2026-06-17

This maintenance release improves current-day diagnostics and makes blocked event
texts safer for generic `eventFn` command templates. Persistence schema 3 remains
unchanged.

### Raw-session diagnostics

- Added the `rawSessionsTodayDiscarded` reading. It counts event-training sessions
  assigned to the current raw-data calendar day whose rounded duration is outside
  the configured `minDuration`/`maxDuration` range.
- The per-day count is stored with the raw calendar day. Existing schema-3 raw days
  without the additive field remain loadable and normalize to zero.
- A DbLog replacement import resets the replaced day count because imported sessions
  replace that day's raw session set.

### File diagnostics

- `get fileInfo` now formats sizes with decimal `B`, `kB`, `MB`, or `GB` units. Values
  through 1000 bytes remain in bytes; larger values use one decimal place.

### Blocked simulation events

- Removed redundant `scope`, normal-case `reason=matched`, and quoting-sensitive
  `actual`/`expression` fields from `simulationEvent` and `$EVENTDETAILS`.
- Normal blocks now report only `condition=<attribute>`. Evaluation failures add the
  static `reason=evaluationError`.
- Full expressions and observed values remain in the FHEM log. Evaluation failures
  are also exposed through the existing `lastError*` readings with source
  `blockCondition`.
- This prevents module-generated double quotes in blocked event text and makes the
  documented `msgText="$EVENT"` use safe for these events.

### Tests

- Expanded the suite to 327 tests. New checks cover current-day discarded counts,
  raw persistence compatibility, file-size units, safe blocked-event expansion, and
  block-evaluation error reporting.

## 1.1.5 — 2026-06-17

This maintenance release removes historically accumulated internal redundancy
without changing public commands, attributes, readings, model behavior, or
persistence schema 3.

### Internal cleanup

- Added canonical constructors for instance data, parsed configuration, and raw
  calendar days, replacing repeated structure literals in define, reload,
  normalization, rename, live training, and DbLog import paths.
- Centralized DbLog import device serialization so the worker parameters and the
  configuration fingerprint use exactly the same device definition.
- Centralized failed-import completion and diagnostic exception handling.
- Centralized local date-time and single-line error formatting plus the shared
  dry-run/playback ON diagnostic.
- Removed duplicate initialization of the existing `lastError*` readings.

### Removed unused runtime data

- Fresh state no longer stores the unused `lastDbLogImportAttemptDate` field.
- Managed playback entries no longer store unused `startedAt`, `bin`, `weekday`,
  or `offSentAt` values.
- Dry-run entries now contain only `offDue`, `durationMinutes`, and `modelType`.
- Device configuration no longer retains its unused attribute-name copy.
- Device models no longer duplicate the session count as `totalSessions`; the
  canonical `deviceTotals` map remains unchanged.
- Same-schema state loaded from 1.1.4 is normalized by removing these unused
  fields; no schema migration is involved.

### Tests

- Expanded the suite to 304 tests. New checks cover the shared constructors,
  canonical import definitions, compact runtime-state shapes, normalization of
  previous schema-3 state, and absence of the removed redundant fields.

## 1.1.4 — 2026-06-17

This maintenance release hardens long-running playback and DbLog worker lifecycle
handling without changing persistence schema 3.

### Playback robustness

- OFF handling now uses one shared bounded state machine for regular session ends,
  `mode off`, disable handling, shutdown, and reload teardown.
- PresenceSimulation sends at most three OFF attempts: immediately, after one
  minute, and after another five minutes. After the final confirmation grace
  period, the managed entry remains unresolved but no more automatic commands are
  sent.
- Retry metadata (`offAttempts`, `offRetryDue`, `offFailed`, and
  `offLastError`) is persisted internally. No additional public reading was added;
  failures use the existing `lastError*` readings and `stoppingPlayback`.
- `set <name> retryOff <device>` starts a new bounded attempt cycle.
- `set <name> forceReleaseManaged <device> confirm` explicitly releases an
  unresolved entry in `mode=off` without treating the physical state as off.
- Shutdown and Undef preserve managed ownership after sending their final bounded
  attempt, allowing restart/reload reconciliation instead of assuming success.

### DbLog worker hardening

- Database connection details and passwords are no longer included in the visible
  `BlockingCall` argument. They are passed through a randomized mode-0600 temporary
  parameter file that the worker removes immediately after reading.
- Queued `BlockingCall` jobs with the FHEM `WAITING:` marker are invalidated and
  removed instead of being left able to start after disable, reset, rename, reload,
  shutdown, or deletion.
- Malformed worker callbacks release import bookkeeping and report an error instead
  of leaving future imports permanently blocked.
- Late callbacks remove result files even when the PresenceSimulation device no
  longer exists.
- Worker errors clean up partially created result files. Old module-owned import
  parameter/result files older than 24 hours are pruned before each import.

### Validation

- `binMinutes` is accepted only as 1, 5, 10, 15, 20, 30, or 60 both in the
  attribute handler and defensively in model/runtime paths.
- `deviceNN maxDuration` is limited to 1440 minutes to bound DbLog query expansion.
- Added `File::Spec` to runtime prerequisites.

### Tests

- Expanded the suite to 285 tests covering bounded OFF retries, persisted retry
  metadata, recovery commands, secure worker parameters, waiting-job cancellation,
  malformed callbacks, orphan-file cleanup, strict `binMinutes`, and the
  `maxDuration` upper limit.

## 1.1.3 — 2026-06-17

This release separates the device that receives playback commands from the device
whose reading represents the observed state.

### Added

- `deviceNN` accepts the optional `readingDevice` key. It defaults to `device`, so
  existing configurations keep their previous behavior.
- `device` remains the logical model key, command target, and `simulationEvent`
  device name. `onCommand` and `offCommand` are always sent to this device.
- `readingDevice` together with `reading` is used for live-event training, current
  playback feedback, manual-intervention detection, restart reconciliation, and
  DbLog queries.
- DbLog rows read from `readingDevice` are reconstructed and stored under the
  logical `device`, allowing historical state data from a separate sensor or
  controller to train a command device.
- Managed playback state persists the observation-device snapshot required for
  safe stop and restart handling. Existing schema-3 state remains valid because
  the new field is optional and older entries fall back to `device`.

### Changed

- The documented `deviceNN` order is now `device`, `onCommand`, `offCommand`,
  `reading`, optional `readingDevice`, regexes, and duration limits.
- The public contact address was removed from source metadata and commandref. The
  META author is now `Flachzange <>`.

### Tests

- Added tests for the default and explicit observation device, live notification
  routing, initial-state lookup, command/observation separation during playback,
  managed-state persistence, missing-source validation, and DbLog mapping from the
  observation device to the logical model device.

## 1.1.2 — 2026-06-16

This release replaces the minute-by-minute hazard draw with one persisted decision
per device and time block.

### Changed

- Each device/time-block pair now receives exactly one probability decision. A miss
  consumes the block without another draw.
- A successful decision creates one pending plan whose start minute is sampled from
  historical start positions inside the block. If simulation starts after all
  retained positions, a minute from the remaining part of the block is selected.
- Durations are sampled when the plan is created and remain attached to that plan.
- Pending real-playback and dry-run plans are stored in schema-3 runtime state so a
  save, reload, or restart does not repeat the block decision. Schema-3 state from
  version 1.1.1 remains loadable because the new planning maps are additive.
- Blocking conditions are evaluated after the plan is due and playback safety checks permit an attempt.
- `get probability` now reports historical block probability, configured factor,
  effective block probability, observed day count, and start-position sample count.
- `simulationEvent` now reports `pHistorical`, effective `pBlock`, `factor`,
  `planned`, and `positionSamples`; the obsolete `pMinute` value was removed.

### Tests

- Added deterministic tests for the exact day-based probability calculation, stored
  start offsets, factor-adjusted diagnostics, one-time block decisions, persisted
  pending plans, scheduled execution, and no-repeat behavior after a miss.

## 1.1.1 — 2026-06-16

This maintenance release fixes state persistence in FHEM environments that import
`Time::HiRes::time` into `package main`.

### Fixed

- All epoch-second values now use explicit `CORE::time()` calls. This prevents
  `lastCoverageTick` and other integer-validated runtime timestamps from becoming
  fractional values and fixes DbLog-import saves failing with
  `state.lastCoverageTick must be a non-negative integer`.
- Added regression coverage that loads the module with high-resolution `time()`
  already imported into the FHEM main package.

### Changed

- FHEMWEB receives an internal, overridable state-icon mapping:
  `off:rc_STOP training:rc_REC dryrun:rc_PLAY playback:rc_PLAYgreen`. No
  `devStateIcon` attribute is created automatically.
- The displayed author name in the source metadata is now `Flachzange`; the
  existing contact address remains unchanged.

## 1.1.0 — 2026-06-16

This release is a fresh-installation hardening and cleanup release. It intentionally introduces persistence schema 3 and new persistence filenames without migration support.

### Safe defaults and configuration

- New instances now start in `mode=off`.
- At least one valid `deviceNN` configuration is required before training, dry-run, playback, or DbLog import can start.
- Event-training coverage is collected only while the complete device/block configuration is valid.
- Configuration failures force active training or simulation back to `off` and discard incomplete event-training sessions.
- Device and model attributes cannot be changed while real playback still owns devices; users must set `mode off` and wait for `stoppingPlayback=0`.

### Playback and lifecycle safety

- Managed playback entries persist the reading, regexes, and off command needed for safe recovery.
- Unknown device states no longer discard managed ownership.
- Unexpected ON feedback no longer contradictorily removes an already-managed device.
- Shutdown and Undef attempt to switch off every managed real device before saving or releasing runtime data.
- Teardown, rename, and reload no longer leave newly scheduled save timers behind.
- Becoming disabled stops managed playback devices; automatic DbLog scheduling resumes when a `disabledForIntervals` period ends.
- Removed the unexplained `NotifyOrderPrefix`; standard FHEM notification ordering is used.
- Uses FHEM's central `IsDisabled()` helper when available and supports `disabledForIntervals`.

### Persistence hardening

- Persistence schema increased from 2 to 3.
- New files use the module name:
  - `PresenceSimulation_Raw_<name>.json`
  - `PresenceSimulation_State_<name>.json`
- Removed the redundant persistent model file. The model is rebuilt in memory from raw data.
- Removed all migration and legacy compatibility paths.
- Added deep validation for raw days, sessions, managed state, expected feedback, played bins, dates, ranges, regexes, and instance ownership.
- Internal data is validated again immediately before saving.
- A semantically invalid main file now falls back to a validated backup.
- Invalid main files are preserved as `.corrupt.<timestamp>` before restoration.
- Backup-copy, restore-copy, rename, and permission errors are checked and reported.
- Main files, backups, restored files, and DbLog worker result files use permissions `0600`.

### DbLog and runtime robustness

- DbLog worker results use randomized `File::Temp` files instead of predictable `/tmp` names.
- Import files are restricted to the FHEM user.
- Existing event and imported days remain available to the shared model; `trainingSource` controls ongoing acquisition only.
- Automatic DbLog scheduling recovers after time-based disable intervals.

### Code and documentation cleanup

- Removed stale release comments and old module/file-name remnants.
- Removed old commandref anchor syntax and historical packaging artifacts.
- Added explicit first-installation instructions and clarified safe playback changes.
- Release artifacts are checked for byte-for-byte equality.
- Expanded the self-test suite to cover lifecycle, disabled-state recovery, pre-save validation, backup recovery, file permissions, schema rejection, and runtime reconciliation.
