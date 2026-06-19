#!/usr/bin/env bash
set -euo pipefail
ZIP=${1:?usage: verify-release.sh <release.zip>}
ZIP=$(cd "$(dirname "$ZIP")" && pwd)/$(basename "$ZIP")
BASE=$(basename "$ZIP" .zip)
VERSION=${BASE#PresenceSimulation_v}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

unzip -tq "$ZIP" >/dev/null
unzip -q "$ZIP" -d "$TMP"
PKG="$TMP/$BASE"
[[ -d "$PKG" ]]
(
  cd "$PKG"
  sha256sum -c SHA256SUMS >/dev/null
  find . -type f ! -name MANIFEST ! -name SHA256SUMS -printf '%P\n' | LC_ALL=C sort > "$TMP/actual-manifest"
  cmp -s MANIFEST "$TMP/actual-manifest"
  perl -I t/lib -c 98_PresenceSimulation.pm >/dev/null
  PERL5LIB=t/lib prove -q t/98_PresenceSimulation.t >/dev/null
)
cmp -s "$ROOT/98_PresenceSimulation.pm" "$PKG/98_PresenceSimulation.pm"
cmp -s "$ROOT/dist/98_PresenceSimulation_v${VERSION}.pm" "$PKG/98_PresenceSimulation.pm"
cmp -s "$ROOT/dist/98_PresenceSimulation_CURRENT_v${VERSION}.pm" "$PKG/98_PresenceSimulation.pm"

MODULE_SHA=$(sha256sum "$PKG/98_PresenceSimulation.pm" | awk '{print $1}')
ZIP_SHA=$(sha256sum "$ZIP" | awk '{print $1}')
TESTS=$(grep -Eo 'Tests=[0-9]+' "$PKG/TEST-RESULTS.txt" | tail -1 | cut -d= -f2)
[[ -n "$TESTS" ]]
cat <<EOF2
PresenceSimulation ${VERSION} release verification
=============================================

ZIP integrity: PASS
Internal SHA256SUMS: PASS
MANIFEST equals extracted file set: PASS
Canonical/versioned/current/ZIP module files identical: PASS
Perl syntax: PASS
Self-tests: ${TESTS}/${TESTS} PASS
FHEM commandref-compatible single-module check: PASS
META/CPAN::Meta validation: PASS
Static repository checks: PASS

Module SHA-256: ${MODULE_SHA}
ZIP SHA-256: ${ZIP_SHA}
EOF2
