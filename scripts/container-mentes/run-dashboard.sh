#!/bin/bash
# Dashboard indító (a marveen-dashboard.service megfelelője).
set -uo pipefail

INSTALL_DIR="/home/marveen/marveen"
cd "$INSTALL_DIR"

# ExecStartPre megfelelője: ha a better-sqlite3 natív binding nem tölthető be a
# jelenlegi Node ABI-hoz, fordítsuk újra. Enélkül "Could not locate the bindings
# file" crash-loop lenne minden Node-verzió váltás után.
if [ -x "./scripts/ensure-native-modules.sh" ]; then
  ./scripts/ensure-native-modules.sh || echo "[dashboard] ensure-native-modules.sh hiba — indítás mindenképp megpróbálva"
fi

# A LimitNOFILE=65535 megfelelője (a compose ulimits-e adja a hard limitet):
# sok tmux subprocess + MCP/SSE kapcsolat mellett az 1024-es alapérték EMFILE-t okoz.
ulimit -n "$(ulimit -Hn)" 2>/dev/null || true

if [ ! -f dist/index.js ]; then
  echo "[dashboard] dist/index.js hiányzik — npm run build"
  npm run build || exit 1
fi

exec node dist/index.js
