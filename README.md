# PresenceSimulation for FHEM

`98_PresenceSimulation.pm` learns completed device on/off sessions and creates a rolling probabilistic presence model. Training data can come from live FHEM events, manual DbLog imports, or automatic DbLog imports. Command targets and observed reading devices can be configured separately. The model can be tested in dry-run mode or used for real playback.

## Installation

Copy the module to the FHEM module directory:

```text
FHEM/98_PresenceSimulation.pm
```

Load it without restarting FHEM:

```text
reload 98_PresenceSimulation.pm
```

Create an instance:

```text
defmod PresenceSimulation PresenceSimulation
```

A new instance starts safely in `mode=off` and requires at least one valid `deviceNN` attribute.

Version 1.1.8 preserves the originally planned end time after a blocked start is
released: the waiting time is subtracted from the sampled duration. If less than one
full minute remains, the plan expires without switching. Persistence schema 3 remains
unchanged.

FHEMWEB uses a module-owned default state-icon mapping without creating an
attribute:

```text
off:rc_STOP training:rc_REC dryrun:rc_PLAY playback:rc_PLAYgreen
```

A normal device-specific `devStateIcon` attribute can override this mapping.

## Minimal event-training setup

```text
attr PresenceSimulation device01 device=Light_Kitchen
set PresenceSimulation mode training
```

The compact device definition uses these defaults:

```text
onCommand=on
offCommand=off
reading=state
readingDevice=<device>
onRegex=^on$
offRegex=^off$
minDuration=1
maxDuration=240  # allowed range: minDuration through 1440
```

`device` is the logical model key and receives the two commands. The optional
`readingDevice` supplies live events, current playback feedback, and DbLog history;
it defaults to `device`.

Example with a separate command and observation device:

```text
attr PresenceSimulation device17 device=DOIF_PresenceSimulation_TV onCommand=cmd_1 offCommand=cmd_2 reading=state readingDevice=KODI onRegex=(?i:^(opened|connected)$) offRegex=(?i:^disconnected$) minDuration=1 maxDuration=240
```

PresenceSimulation sends `cmd_1`/`cmd_2` to `DOIF_PresenceSimulation_TV`, but learns
and imports `KODI:state`. The reconstructed sessions remain stored under the logical
name `DOIF_PresenceSimulation_TV`.

## Quick start with DbLog history

```text
attr PresenceSimulation device01 device=Light_Kitchen
attr PresenceSimulation dbLogDevice DbLog
set PresenceSimulation importDbLog 30
get PresenceSimulation importInfo
get PresenceSimulation modelInfo
set PresenceSimulation mode dryrun
```

For each configured logical device, the import queries `readingDevice:reading` and
assigns the reconstructed sessions to `device`. This also makes existing history
from a separate observation device directly usable. Database credentials are
passed to the nonblocking worker through a randomized mode-0600 parameter file and
do not appear in FHEM's visible `BlockingCall` argument.

For daily automatic imports, set the DbLog device first and then use:

```text
attr PresenceSimulation trainingSource dblog
```

## Probability model

For every configured device and time block, the historical block probability is
calculated as:

```text
usable days with at least one start in the block / all usable days
```

`probabilityFactor` is applied once to this block probability and the result is
limited to 100 %. Dry-run and playback then make exactly one decision for each
device/time-block pair. A miss consumes the block. A hit creates one pending plan
whose start minute is sampled from historical positions inside the block and whose
duration is sampled from historical durations. Pending plans are stored in runtime
state, so a save or reload does not repeat the decision. If a blocking condition is
active at the planned start, one `action=blocked` event is emitted with `pending=1`
and `retryUntil=HH:MM`. The plan is checked again on every simulation tick until the
block ends. If the condition clears, `action=on` includes `started=HH:MM` and
`delayed=Nmin`. The delay is subtracted from `duration`, so the originally planned
end time remains unchanged. If less than one full minute remains, the plan expires
without switching or another event. A plan still blocked at the boundary expires
without a second blocked event.

Use this command to inspect the historical and effective values:

```text
get PresenceSimulation probability <device> <HH:MM> [weekday]
```

The current block model intentionally allows at most one simulated start per device
and time block. It does not preserve the complete daily number or order of sessions.

## Safe playback workflow

Check the model and test dry-run output before sending real commands:

```text
get PresenceSimulation modelInfo
set PresenceSimulation mode dryrun
set PresenceSimulation mode playback
```

To stop real playback safely:

```text
set PresenceSimulation mode off
```

Wait until `stoppingPlayback` is `0` before changing device or model attributes.

An unresolved OFF state is attempted at most three times: immediately, after one
minute, and after another five minutes. If the state is still not confirmed after
the final grace period, PresenceSimulation keeps ownership but sends no more
automatic commands. The existing `lastError*` readings report the problem; no
additional failure reading is created.

A new bounded cycle can be started explicitly:

```text
set PresenceSimulation retryOff <device>
```

As a last-resort recovery in `mode=off`, an unresolved entry can be released
without claiming that the device is physically off:

```text
set PresenceSimulation forceReleaseManaged <device> confirm
```

## Diagnostics and blocked-plan behavior

`rawSessionsTodayDiscarded` counts event-training sessions assigned to the current
raw-data calendar day whose rounded duration was outside the configured
`minDuration`/`maxDuration` range. Such sessions remain excluded from
`rawSessionsToday`.

`get PresenceSimulation fileInfo` uses decimal units: values through 1000 bytes are
shown in `B`, then `kB`, `MB`, or `GB` with one decimal place.

Blocked `simulationEvent` values contain the matching `condition` only. A static
`reason=evaluationError` is added only when evaluation itself failed. Configured
expressions and observed values remain in the FHEM log instead of being inserted into
the event text, which keeps `$EVENT` safe for quoted command parameters such as
`msgText="$EVENT"`.

## Persistence

The module stores only raw data and runtime state below `FHEM/FhemUtils`:

```text
PresenceSimulation_Raw_<name>.json
PresenceSimulation_State_<name>.json
```

The probability model is rebuilt in memory. Persistent files and backups are written with permissions `0600`. Schema version 3 is required; this release intentionally contains no migration or legacy compatibility code.

Version 1.1.1 introduced explicit integer `CORE::time()` values for persisted epoch
timestamps. This avoids fractional `lastCoverageTick` values in FHEM environments
that expose `Time::HiRes::time` in `package main`.

## Documentation

The full English and German command reference is embedded in the module and becomes available through the FHEM command reference after installation.

## Repository development workflow

`98_PresenceSimulation.pm` in the repository root is the only authoritative module
source. Versioned module copies, release ZIP files, MANIFEST files, test transcripts,
and SHA-256 files are generated and are not edited or committed.

Run all source checks locally with:

```bash
scripts/ci.sh
```

Build and independently verify a complete release with:

```bash
scripts/build-release.sh
```

Generated files are written to `dist/`. GitHub Actions runs the same checks for every
push and pull request. A tag matching the embedded module version, for example
`v1.1.8`, builds the release and publishes the verified artifacts through GitHub
Releases.

Codex instructions and project invariants are maintained in `AGENTS.md`. Changes
should be made on focused `codex/<description>` branches and submitted as draft pull
requests. Real FHEM, DbLog, device, playback, shutdown, and restart tests remain a
separate manual release requirement and must be reported honestly.
