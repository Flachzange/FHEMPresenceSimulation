#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

perl -I t/lib -c 98_PresenceSimulation.pm
PERL5LIB=t/lib prove -v t/98_PresenceSimulation.t
perl scripts/check_meta.pl
perl scripts/check_commandref.pl
perl scripts/check_repository.pl
