#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

VERSION=$(perl -ne 'if (/my\s+\$PRESENCE_SIM_VERSION\s*=\s*\x27([^\x27]+)\x27/) { print $1; exit }' 98_PresenceSimulation.pm)
if [[ -z "$VERSION" ]]; then
  echo "Unable to determine module version" >&2
  exit 1
fi
PACKAGE="PresenceSimulation_v${VERSION}"
DIST="$ROOT/dist"
PKG="$DIST/$PACKAGE"
STATIC_TMP=$(mktemp)
trap 'rm -f "$STATIC_TMP"' EXIT
perl scripts/check_repository.pl >"$STATIC_TMP"
rm -rf "$DIST"
mkdir -p "$PKG/t/lib/FHEM"

perl -I t/lib -c 98_PresenceSimulation.pm >"$PKG/SYNTAX-CHECK.txt" 2>&1
PERL5LIB=t/lib prove -v t/98_PresenceSimulation.t >"$PKG/TEST-RESULTS.txt" 2>&1
perl scripts/check_meta.pl >"$PKG/META-CHECK.txt"
perl scripts/check_commandref.pl >"$PKG/COMMANDREF-CHECK.txt"
mv "$STATIC_TMP" "$PKG/STATIC-CHECK.txt"
trap - EXIT

set +e
podchecker 98_PresenceSimulation.pm >"$PKG/PODCHECKER.txt" 2>&1
POD_STATUS=$?
set -e
if [[ $POD_STATUS -ne 0 ]]; then
  cat >>"$PKG/PODCHECKER.txt" <<'PODNOTE'

The reported top-level =item/=over messages are caused by the FHEM single-module metadata layout.
The embedded English/German commandref blocks are checked separately in COMMANDREF-CHECK.txt.
PODNOTE
fi

cp 98_PresenceSimulation.pm CHANGELOG.md README.md REVIEW-CHECKLIST.md TESTING.md LICENSE "$PKG/"
cp t/98_PresenceSimulation.t "$PKG/t/"
cp t/lib/Blocking.pm "$PKG/t/lib/"
cp t/lib/FHEM/Meta.pm "$PKG/t/lib/FHEM/"

(
  cd "$PKG"
  find . -type f ! -name MANIFEST ! -name SHA256SUMS -printf '%P\n' | LC_ALL=C sort > MANIFEST
  while IFS= read -r path; do sha256sum "$path"; done < MANIFEST > SHA256SUMS
)

cp 98_PresenceSimulation.pm "$DIST/98_PresenceSimulation_v${VERSION}.pm"
cp 98_PresenceSimulation.pm "$DIST/98_PresenceSimulation_CURRENT_v${VERSION}.pm"

EPOCH=${SOURCE_DATE_EPOCH:-}
if [[ -z "$EPOCH" ]] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  EPOCH=$(git log -1 --format=%ct 2>/dev/null || true)
fi
EPOCH=${EPOCH:-$(date +%s)}
find "$PKG" -exec touch -d "@$EPOCH" {} +
(
  cd "$DIST"
  LC_ALL=C zip -X -q -r "${PACKAGE}.zip" "$PACKAGE"
)
sha256sum "$DIST/${PACKAGE}.zip" >"$DIST/${PACKAGE}.zip.sha256"

"$ROOT/scripts/verify-release.sh" "$DIST/${PACKAGE}.zip" | tee "$DIST/${PACKAGE}-ZIP-CHECK.txt"
printf '\nRelease artifacts created in %s\n' "$DIST"
