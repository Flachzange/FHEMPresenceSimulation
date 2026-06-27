# Testing PresenceSimulation 1.1.9

Expected self-test result for this release: **378/378 PASS**.

## Automated checks

Run from the package directory:

```bash
perl -I t/lib -c 98_PresenceSimulation.pm
PERL5LIB=t/lib prove -v t/98_PresenceSimulation.t
```

The 364 self-tests use small FHEM stubs and cover parsing, exact day-based model
probabilities, historical start positions, one-time block decisions, persisted
pending plans, factor-adjusted diagnostics, mixed event/DbLog history, manual
imports, event handlers, persistence, backups, permissions, lifecycle cleanup,
managed playback recovery, disabled-state handling, commandref content, and META
data. They additionally verify separate command and observation devices, bounded
OFF retries and persisted retry state, explicit recovery commands, strict
`binMinutes`/`maxDuration` validation, secure DbLog parameter files, cancellation
of queued `WAITING:` workers, malformed callback recovery, and orphan result-file
cleanup. They also cover canonical instance/config/raw-day constructors,
canonical import-device serialization, compact managed and dry-run state,
same-schema cleanup of unused 1.1.4 fields, and the absence of redundant model
and configuration copies. The module is compiled with `Time::HiRes::time`
imported into `package main` to verify integer state timestamps plus the internal
FHEMWEB icon default.

## Recommended FHEM integration test

1. Install and load the module:

   ```text
   reload 98_PresenceSimulation.pm
   defmod PresenceSimulation PresenceSimulation
   ```

2. Confirm the safe initial state:

   ```text
   list PresenceSimulation
   ```

   Expected: `mode off`, `state off`, and a configuration error until `device01` is set.

3. Configure one test device and start event training:

   ```text
   attr PresenceSimulation device01 device=<test-device>
   set PresenceSimulation mode training
   ```

4. Verify `on`/`off` events create completed raw sessions.

5. Test a separate observation device, for example:

   ```text
   attr PresenceSimulation device02 device=<command-device> onCommand=<on-command> offCommand=<off-command> reading=<reading> readingDevice=<observation-device> onRegex=<on-regex> offRegex=<off-regex>
   ```

   Confirm that live events and current-state checks come from the observation
   device while commands are sent only to the command device.

6. Test a manual DbLog import:

   ```text
   attr PresenceSimulation dbLogDevice <DbLog-device>
   set PresenceSimulation importDbLog 7
   get PresenceSimulation importInfo
   get PresenceSimulation modelInfo
   ```

7. Run dry-run mode and inspect `simulationEvent`:

   ```text
   set PresenceSimulation mode dryrun
   get PresenceSimulation probability <test-device> <HH:MM>
   ```

   Verify that one block decision creates at most one pending event, that the event
   occurs at a plausible historical minute within the block, and that the event text
   contains `pHistorical`, `pBlock`, `factor`, and `planned`. Reload FHEM while a plan
   is pending and confirm that the decision is not repeated.

8. Test a blocking condition. Verify that the first blocked check emits exactly one
   `action=blocked` event with `pending=1` and `retryUntil=HH:MM`, repeated checks emit
   no duplicate event, a release within the block produces `action=on` with `started`
   and `delayed`, with the waiting time removed from `duration` so the original end
   time remains unchanged. Verify that a plan with less than one minute remaining
   expires without an ON event, and that a continuously blocked plan expires at the
   block boundary without a second blocked event.

9. Test real playback only with a harmless test device. Set the module to `off`
   and verify the device is switched off and `stoppingPlayback` returns to `0`.
   Also suppress the OFF feedback on a test device and confirm that exactly three
   attempts occur, no further commands are sent, `lastErrorSource=playback`, and
   `retryOff` starts one new bounded cycle.

10. Test `disable` and `disabledForIntervals` while playback owns a test device.

11. Confirm persistence files below `FHEM/FhemUtils` are mode `0600` and that restart/reload restores current schema-3 state.

A real FHEM/DbLog integration test is still required before changing the release status from `testing`/`experimental`.

## 1.1.9 focused checks

- Configure an `eventFn`, set `eventFnEnabled 0`, and trigger dry-run and playback
  events. Verify that `simulationEvent` continues to update while the handler command
  is not executed.
- Set `eventFnEnabled 1` and verify that the unchanged stored handler runs again.
  Delete `eventFnEnabled` and confirm that the effective default is also enabled.
- Toggle the attribute while a real or dry-run plan is pending. Verify that no module
  reinitialization occurs and that the pending plan remains intact.
- Produce an error with `lastErrorSource=eventFn`, disable the handler, and verify that
  the error is cleared. Repeat with a different error source and verify that it is
  preserved.
- Attempt to configure an empty `eventFn` while `eventFnEnabled=0`; validation must
  still reject the empty handler.

## 1.1.8 focused checks

- Complete one session below `minDuration` and verify that
  `rawSessionsTodayDiscarded` increases while `rawSessionsToday` does not.
- Run `get <name> fileInfo` with files above 1000 bytes and verify decimal `kB`/`MB`
  formatting.
- Trigger a normal and an evaluation-error blocking condition with
  `eventFn ... msgText="$EVENT"`; verify that the event contains no configured
  expression or observed value and that only the error case adds
  `reason=evaluationError`.

- Confirm that a delayed start reports the reduced duration and retains the original
  planned end time in both dry-run and playback.
- Confirm that a released plan with less than one minute remaining does not switch and
  emits no event after the initial pending blocked event.
- Reload FHEM while a blocked plan is pending and confirm that the initial blocked
  notification is not repeated.
- Verify the same pending-block behavior in both dry-run and real playback with a
  harmless command device.
