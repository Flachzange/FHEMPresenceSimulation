# Review checklist for PresenceSimulation 1.1.8

Release self-test baseline: **364/364 PASS**.

## Implemented

- Safe first-installation default: `mode=off`.
- Configuration readiness requires at least one valid `deviceNN` and no parse errors.
- No event-training coverage is recorded for an empty or invalid configuration.
- Playback-sensitive attributes are locked while real devices are still managed.
- Managed sessions contain a durable stop-command snapshot.
- Shutdown and Undef attempt to switch off managed real devices.
- Teardown prevents new delayed-save timers.
- Unknown readings retain managed ownership and create a runtime error.
- Unexpected ON feedback keeps existing ownership consistent.
- FHEM `IsDisabled()` and `disabledForIntervals` are supported.
- Automatic DbLog scheduling resumes when a time-based disable interval ends.
- Unexplained notification-order override removed.
- DbLog worker uses randomized mode-0600 `File::Temp` output.
- Persistence uses schema 3 and module-specific filenames.
- Redundant persistent model cache removed.
- Raw and state structures are deeply validated on load and immediately before save.
- A semantically invalid main file can be restored from a validated backup.
- Invalid main files are archived before backup restoration.
- Copy, rename, chmod, and restore failures are reported.
- Persistent files and backups use mode `0600`.
- Old names, migration helpers, legacy compatibility, old anchors, and historical package patches removed.
- Release build checks separate, versioned, and ZIP-contained module files for byte equality.
- Persisted epoch timestamps explicitly bypass an imported `Time::HiRes::time` and remain integers.
- FHEMWEB receives an internal, user-overridable `devStateIcon` mapping without automatic attribute creation.
- Source metadata displays the author name `Flachzange`.
- Block probabilities are evaluated once per device/time-block pair instead of once per minute.
- Historical start offsets are retained and sampled for pending block plans.
- Pending real and dry-run plans are persisted and deeply validated.
- A blocked due plan emits one pending blocked event, remains persisted until the
  current time block ends, and is rechecked without another probability draw.
- A later release emits one ON event with actual start and delay, subtracts the wait
  from the duration, and preserves the original planned end time. If less than one
  minute remains, no ON command or event is produced. Permanent blocking expires
  silently at the boundary without a duplicate blocked event.
- Version-1.1.1 schema-3 state remains loadable without planning maps.
- Probability diagnostics distinguish historical, factor-adjusted, and effective values.
- Optional `readingDevice` cleanly separates the command target from the observed
  live/DbLog state while defaulting to the command device.
- Notification routing, current-state checks, manual-intervention detection,
  playback reconciliation, and DbLog imports use the configured observation device.
- Raw sessions, model keys, commands, and `simulationEvent` continue to use the
  logical command device.
- Managed stop snapshots persist the observation device without increasing the
  persistence schema; older schema-3 entries remain valid.
- Public contact-address metadata has been removed; the author is `Flachzange <>`.
- OFF handling is bounded to three attempts and persists unresolved ownership
  without adding another public reading.
- Explicit `retryOff` and confirmed `forceReleaseManaged` recovery paths are
  documented and tested.
- DbLog credentials are absent from visible BlockingCall arguments and use a
  randomized mode-0600 parameter file.
- Queued `WAITING:` BlockingCall jobs are invalidated on abort.
- Malformed and late worker callbacks release bookkeeping and temporary files.
- `binMinutes` is strictly validated and `maxDuration` is capped at 1440 minutes.
- Repeated instance, configuration, raw-day, import-failure, and diagnostic
  structures are centralized without changing public behavior.
- Unused state/config/model fields are no longer produced; previous schema-3
  state is normalized to the compact runtime shape.

## Automated verification

- Perl syntax check.
- 364 self-tests.
- Embedded META JSON parse and CPAN metadata validation.
- FHEM `commandref_join.pl`-compatible single-module checks for English and German blocks.
- HTML parse and duplicate-anchor checks.
- Static callback, subroutine, naming, line-length, persistence, and legacy-remnant checks.
- ZIP extraction, manifest, and SHA-256 checks.

## Remaining integration work

The automated suite uses FHEM stubs. Before publication beyond `testing`/`experimental`, test the release in a real FHEM installation with:

- real FHEMWEB attribute handling,
- a real DbLog database,
- `BlockingCall` lifecycle and timeout behavior,
- actual device command feedback,
- separate command and observation devices, including historical DbLog import,
- FHEM shutdown/restart,
- `disabledForIntervals`,
- and harmless real playback devices.

## 1.1.8 pending blocked plans

- [ ] `rawSessionsTodayDiscarded` counts only duration-rejected event-training
  sessions assigned to the current raw-data day.
- [ ] Schema-3 raw days without `discardedSessions` remain valid.
- [ ] `fileInfo` keeps values through 1000 bytes in `B` and uses decimal larger units.
- [ ] Normal blocked events contain `condition` but no `scope`, `reason=matched`,
  `actual`, or `expression`.
- [ ] Evaluation failures add only `reason=evaluationError`, retain detailed log
  diagnostics, and use `lastErrorSource=blockCondition`.

- [ ] First blocked check contains `pending=1` and `retryUntil=HH:MM`.
- [ ] Continued blocking creates no duplicate `simulationEvent` or `eventFn` call.
- [ ] Release in the same block creates ON with `started=HH:MM` and `delayed=Nmin`.
- [ ] The wait is subtracted from `duration`, preserving the originally planned end.
- [ ] A released plan with less than one minute remaining expires without ON or a
      second event.
- [ ] A plan still blocked at the boundary is discarded without a second blocked event.
