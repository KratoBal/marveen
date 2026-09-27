#!/bin/bash
# Marveen konténer entrypoint.
#
# Módok:
#   run      (alapértelmezett) — supervisord alatt indítja a dashboardot + a channel bridge-et
#   setup    — interaktívan lefuttatja a hivatalos install-linux.sh-t
#   update   — lefuttatja a repó saját update.sh-ját
#   doctor   — scripts/doctor.sh
#   shell    — bash a marveen user alatt
#   <egyéb>  — a kapott parancsot futtatja marveen userként
#
# Root-ként indul (kell a chown / cron / timezone miatt), majd gosu-val
# leejti a jogokat a marveen userre.

set -euo pipefail

MARVEEN_HOME="/home/marveen"
INSTALL_DIR="${MARVEEN_HOME}/marveen"
REPO_URL="${MARVEEN_REPO:-https://github.com/Szotasz/marveen.git}"
REPO_REF="${MARVEEN_REF:-main}"
WEB_PORT_VAL="${WEB_PORT:-3420}"
WEB_HOST_VAL="${MARVEEN_WEB_HOST:-0.0.0.0}"

c_ok()   { echo -e "\033[0;32m  ✓\033[0m $*"; }
c_warn() { echo -e "\033[0;33m  !\033[0m $*"; }
c_err()  { echo -e "\033[0;31m  ✗\033[0m $*" >&2; }
c_hdr()  { echo -e "\n\033[1m$*\033[0m"; }

as_marveen() { gosu marveen "$@"; }

# ── Időzóna ──────────────────────────────────────────────────────────────────
# A telepítő és a systemd-pótló cron is a rendszer TZ-jét olvassa; UTC-n a
# reggeli napindító és minden ütemezett feladat rossz órakor sülne el.
if [ -n "${TZ:-}" ] && [ -f "/usr/share/zoneinfo/${TZ}" ]; then
  ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime
  echo "${TZ}" > /etc/timezone
fi

# ── Kötet jogosultságok ──────────────────────────────────────────────────────
# A bind mount a hoston jellemzően root tulajdonú; a konténerbeli marveen
# user (uid 1000) különben nem tud belé írni.
if [ "$(stat -c %u "$MARVEEN_HOME")" != "$(id -u marveen)" ]; then
  echo "  Kötet jogosultságok igazítása (${MARVEEN_HOME})..."
  chown "$(id -u marveen):$(id -g marveen)" "$MARVEEN_HOME"
fi
# Ha a kötet tartalma más tulajdonossal került ide (pl. root-ként visszaállított
# backup), rekurzívan is igazítunk — de csak akkor, mert nagy store/ mellett a
# chown -R minden indításnál percekig tartana.
if [ -d "${MARVEEN_HOME}/marveen" ] && ! gosu marveen test -w "${MARVEEN_HOME}/marveen"; then
  c_warn "A telepítési könyvtár nem írható a marveen userrel — rekurzív chown fut (eltarthat egy ideig)..."
  chown -R "$(id -u marveen):$(id -g marveen)" "$MARVEEN_HOME"
fi
for d in .claude .npm-global .config .local .cache; do
  install -d -o marveen -g marveen "${MARVEEN_HOME}/${d}"
done

# ── Repó bootstrap ───────────────────────────────────────────────────────────
if [ ! -d "${INSTALL_DIR}/.git" ]; then
  c_hdr "Marveen forrás letöltése (${REPO_REF})..."
  as_marveen git clone --branch "$REPO_REF" "$REPO_URL" "$INSTALL_DIR"
  c_ok "Klónozva: ${INSTALL_DIR}"
fi

# ── .env kulcs upsert ────────────────────────────────────────────────────────
# FONTOS: a Marveen a konfigot KIZÁRÓLAG a .env fájlból olvassa (src/env.ts),
# a konténer environmentjéből NEM. Amit a compose-ban állítasz, azt ide kell
# átvezetni, különben nincs hatása.
set_env_kv() {
  local key="$1" val="$2" file="${INSTALL_DIR}/.env"
  [ -f "$file" ] || return 0
  if grep -qE "^[#[:space:]]*${key}=" "$file"; then
    sed -i -E "s|^[#[:space:]]*${key}=.*|${key}=${val}|" "$file"
  else
    printf '%s=%s\n' "$key" "$val" >> "$file"
  fi
}

apply_container_env() {
  [ -f "${INSTALL_DIR}/.env" ] || return 0
  # A 127.0.0.1-es alapérték konténerben azt jelenti, hogy a dashboard csak a
  # konténeren BELÜLRŐL érhető el — a port-mapping ilyenkor némán nem működik.
  set_env_kv WEB_HOST "$WEB_HOST_VAL"
  set_env_kv WEB_PORT "$WEB_PORT_VAL"
  [ -n "${OLLAMA_URL:-}" ] && set_env_kv OLLAMA_URL "$OLLAMA_URL"
  [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && set_env_kv CLAUDE_CODE_OAUTH_TOKEN "$CLAUDE_CODE_OAUTH_TOKEN"
  chown marveen:marveen "${INSTALL_DIR}/.env"
}

is_installed() {
  [ -f "${INSTALL_DIR}/.env" ] && [ -d "${INSTALL_DIR}/node_modules" ]
}

# ── Cron (a systemd timerek pótlása) ─────────────────────────────────────────
# A hivatalos telepítő systemd user timert rak a reggeli napindítóra.
# Konténerben nincs systemd, ezért cronból hívjuk ugyanazt a scriptet.
setup_cron() {
  local hhmm="${MORNING_BRIEFING_AT:-07:27}"
  local hh="${hhmm%%:*}" mm="${hhmm##*:}"
  if [ "${MORNING_BRIEFING_ENABLED:-1}" != "1" ]; then
    rm -f /etc/cron.d/marveen
    return 0
  fi
  cat > /etc/cron.d/marveen <<EOF
# Marveen — reggeli napindító (a systemd timer pótlása)
SHELL=/bin/bash
PATH=${MARVEEN_HOME}/.npm-global/bin:${MARVEEN_HOME}/.local/bin:${MARVEEN_HOME}/.bun/bin:/usr/local/bin:/usr/bin:/bin
HOME=${MARVEEN_HOME}
${mm#0} ${hh#0} * * * marveen cd ${INSTALL_DIR} && ./scripts/morning-briefing.sh >> ${INSTALL_DIR}/store/morning.log 2>&1
EOF
  chmod 0644 /etc/cron.d/marveen
}

MODE="${1:-run}"

case "$MODE" in

  setup)
    c_hdr "Marveen telepítő (hivatalos install-linux.sh, konténerben)"
    echo "  Telepítési könyvtár: ${INSTALL_DIR}"
    echo ""
    if [ -t 0 ]; then :; else
      c_err "A telepítő interaktív — TTY nélkül nem fut le."
      echo "  Használd:  docker compose run --rm -it marveen setup" >&2
      exit 1
    fi
    # A [7/7] systemd lépést a telepítő magától átugorja konténerben
    # (`pidof systemd && systemctl --user status` őrfeltétel), így nem kell
    # patchelni semmit — a szolgáltatásokat utána a supervisord viszi.
    cd "$INSTALL_DIR"
    as_marveen env \
      HOME="$MARVEEN_HOME" \
      PATH="$PATH" \
      TZ="${TZ:-UTC}" \
      CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-}" \
      MARVEEN_ENV="linux-server" \
      bash "${INSTALL_DIR}/install-linux.sh" || {
        c_err "A telepítő hibával állt le. A fenti kimenet mutatja, melyik lépésnél."
        exit 1
      }
    apply_container_env
    c_hdr "Kész."
    echo "  Indítás:  docker compose up -d"
    echo "  Napló:    docker compose logs -f"
    ;;

  update)
    is_installed || { c_err "Még nincs telepítve. Előbb: docker compose run --rm -it marveen setup"; exit 1; }
    cd "$INSTALL_DIR"
    as_marveen env HOME="$MARVEEN_HOME" PATH="$PATH" bash ./update.sh
    apply_container_env
    ;;

  doctor)
    cd "$INSTALL_DIR"
    as_marveen env HOME="$MARVEEN_HOME" PATH="$PATH" bash ./scripts/doctor.sh
    ;;

  shell)
    cd "$INSTALL_DIR" 2>/dev/null || cd "$MARVEEN_HOME"
    exec gosu marveen env HOME="$MARVEEN_HOME" PATH="$PATH" TZ="${TZ:-UTC}" bash -l
    ;;

  run)
    if ! is_installed; then
      c_hdr "A Marveen még nincs telepítve ebben a kötetben."
      echo ""
      echo "  Futtasd egyszer, interaktívan:"
      echo ""
      echo "      docker compose run --rm -it marveen setup"
      echo ""
      echo "  Utána:  docker compose up -d"
      echo ""
      # Nem crash-loopolunk: aludjunk, hogy a `docker compose logs` olvasható
      # maradjon és a restart policy ne pörgesse fel a gépet.
      sleep infinity
    fi

    apply_container_env
    setup_cron

    # A natív better-sqlite3 binding újrafordítása, ha a jelenlegi Node ABI-hoz
    # nem tölthető be (image-frissítés / Node major váltás után). Ugyanaz, amit
    # a systemd unit ExecStartPre-ként hívna.
    if [ -x "${INSTALL_DIR}/scripts/ensure-native-modules.sh" ]; then
      as_marveen env HOME="$MARVEEN_HOME" PATH="$PATH" \
        bash "${INSTALL_DIR}/scripts/ensure-native-modules.sh" || \
        c_warn "ensure-native-modules.sh hibára futott — a dashboard indulása ettől még megpróbálkozik."
    fi

    # dist/ build, ha hiányzik (pl. friss git pull után)
    if [ ! -f "${INSTALL_DIR}/dist/index.js" ]; then
      c_warn "dist/index.js hiányzik — build indul..."
      if ! ( cd "$INSTALL_DIR" && as_marveen env HOME="$MARVEEN_HOME" PATH="$PATH" npm run build ); then
        c_err "A build elbukott. Nézd meg a fenti hibát, majd:"
        echo "    docker compose run --rm -it marveen shell   →   npm install && npm run build" >&2
        # Nem lépünk ki hibával: a restart policy különben végtelen újraindítási
        # ciklusba vinné a konténert, és a napló olvashatatlan lenne.
        sleep infinity
      fi
    fi

    install -d -o marveen -g marveen "${INSTALL_DIR}/store"

    c_hdr "Marveen indul (supervisord)"
    echo "  Dashboard:  http://127.0.0.1:${WEB_PORT_VAL}  (a hoston)"
    echo "  Naplók:     docker compose logs -f"
    echo ""
    exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
    ;;

  *)
    cd "$INSTALL_DIR" 2>/dev/null || cd "$MARVEEN_HOME"
    exec gosu marveen env HOME="$MARVEEN_HOME" PATH="$PATH" TZ="${TZ:-UTC}" "$@"
    ;;
esac
