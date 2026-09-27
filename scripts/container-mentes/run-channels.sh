#!/bin/bash
# Channel bridge indító (a marveen-channels.service megfelelője).
#
# A channels.sh tmux sessionben indítja a claude processzt, és addig él, amíg a
# session él. Kilépés után a supervisord újraindítja (autorestart=true), ami a
# hivatalos unit Restart=always viselkedésének felel meg.
set -uo pipefail

INSTALL_DIR="/home/marveen/marveen"
cd "$INSTALL_DIR"

# A dashboard előbb álljon fel: a channels.sh a store/ adatbázist és a
# dashboard által írt állapotot is olvassa induláskor.
sleep "${CHANNELS_START_DELAY:-8}"

ulimit -n "$(ulimit -Hn)" 2>/dev/null || true

exec bash ./scripts/channels.sh
