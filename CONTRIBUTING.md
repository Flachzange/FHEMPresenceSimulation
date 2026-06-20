# Contributing

`98_PresenceSimulation.pm` is the only technical source of truth for the module.
Do not use generated or versioned copies as development sources.

All changes must be made on a branch and submitted through a pull request. Working
branches use the `codex/` prefix. Before opening a pull request, run the complete
CI suite successfully:

```sh
scripts/ci.sh
```

Generated release artifacts in `dist/` must not be committed. Releases are created
from version tags in the form `vX.Y.Z`.

Real integration testing with FHEM, DbLog, devices, and playback must be documented
separately; the CI suite does not replace those tests.
