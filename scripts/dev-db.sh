#!/usr/bin/env bash
# ANSWERS: Tudok-e HELYBEN integracios tesztet futtatni? (van-e postgres/redis, es fut-e)
# Local development database for the fleet container.
#
# Why this exists: an acropora-os working copy MAY carry a .env whose
# DATABASE_URL points at the LIVE database, so "just run the app" is not a
# safe instruction. Check before you trust either half of that sentence:
# measured 2026-09-01 13:52, nautilus's working copy had NO .env at all (not
# at the root, not under packages/database, not under apps/api), so the
# warning described a state that was not theirs. A header that overstates is
# read once and discounted afterwards, which is how a real warning dies.
#
# This script runs a PostgreSQL 16 (same major version the
# CI workflow uses) and a Redis on localhost inside this container, with a
# database that exists only here.
#
# There is no systemd in this container, so the services are started directly
# and do NOT come back on their own after a container restart. Run
# `dev-db.sh start` again after one; `dev-db.sh status` says whether they run.
set -u

PG_BIN=/usr/lib/postgresql/16/bin
DEV_DB=acropora_dev
DEV_USER=acropora
DEV_PASS=acropora

usage() {
  cat <<'EOF'
Usage: dev-db.sh <command>

  start    start PostgreSQL 16 and Redis (idempotent)
  stop     stop both
  status   report whether each answers, with versions
  url      print the connection strings to use
  reset    drop and recreate the acropora_dev database (local only)
EOF
}

# HAROM VILAG, EGY MONDAT -- ES EDDIG MIND A HAROM "DOWN" VOLT (sajat meres,
# 2026-09-22). A postgres es a redis ELTUNT ebbol a konteneribol (a 09-01-i
# ujraletrehozas vitte el), a sudoers szabalyok viszont TULELTEK: a
# `/usr/bin/pg_ctlcluster` NOPASSWD joga ma is all, a binaris nem letezik.
#
# ES A HIBAUZENET EZT ELREJTI, mert a SZO SZERINTI ALAKON mulik:
#
#   sudo pg_ctlcluster 16 main start     ->  "sudo: a password is required"
#   sudo -n /usr/bin/pg_ctlcluster ...   ->  "sudo: /usr/bin/...: command not found"
#
# Ugyanaz a hianyzo fajl. Rovid alaknal a sudo nem tudja feloldani a nevet, tehat
# EGYETLEN szabalyra sem illeszkedik, es a vegen jelszot ker -- vagyis egy TELEPITESI
# hiany JOGOSULTSAGI hibakent jelenik meg. Aki ezt latja, sudo jogot fog kerni ahhoz,
# ami nincs feltelepitve. A szkript ezert a TELJES UTVONALAT hasznalja mindenhol.
#
# A regi `pg_running` a sudo hibajat 2>/dev/null-ba nyelte, tehat a "nincs telepitve",
# a "nincs jogom megkerdezni" es a "tenyleg all" mind ugyanazt a sort adta.
have() { [ -x "$1" ]; }

PG_CTL=/usr/bin/pg_ctlcluster
PG_ISREADY="$PG_BIN/pg_isready"
REDIS_SERVER=/usr/bin/redis-server
REDIS_CLI=/usr/bin/redis-cli

pg_installed() { have "$PG_CTL" && have "$PG_ISREADY"; }
redis_installed() { have "$REDIS_SERVER" && have "$REDIS_CLI"; }
pg_running() { pg_installed && sudo -n -u postgres "$PG_ISREADY" -q -h 127.0.0.1 2>/dev/null; }
redis_running() { redis_installed && "$REDIS_CLI" ping >/dev/null 2>&1; }

case "${1:-}" in
  start)
    hiany=0
    pg_installed || { echo "postgres: NINCS TELEPITVE ($PG_CTL hianyzik) -- a sudo jog megvan, a binaris nem. Ez TELEPITESI kerdes, sudo nem oldja meg." >&2; hiany=1; }
    redis_installed || { echo "redis:    NINCS TELEPITVE ($REDIS_SERVER hianyzik) -- ugyanaz." >&2; hiany=1; }
    [ "$hiany" -eq 0 ] || exit 3
    pg_running || sudo -n "$PG_CTL" 16 main start
    redis_running || sudo -n "$REDIS_SERVER" /etc/redis/redis.conf --daemonize yes
    sleep 1
    "$0" status
    ;;
  stop)
    pg_installed && sudo -n "$PG_CTL" 16 main stop
    redis_installed && "$REDIS_CLI" shutdown nosave >/dev/null 2>&1
    echo "stopped"
    ;;
  status)
    # A HAROM ALLAPOT KULON SZOVAL MEGY KI. Egy "DOWN", ami a hianyt is jelenti,
    # nem allapotjelzes, hanem talalgatasra biztatas.
    if ! pg_installed; then
      echo "postgres: NINCS TELEPITVE   ($PG_CTL nem letezik; a sudoers szabaly TULELTE a binarist)"
    elif pg_running; then
      echo "postgres: UP   $(sudo -n -u postgres psql -tAc 'select version();' | cut -d, -f1)"
    else
      echo "postgres: ALL  (telepitve van, de nem fut -- 'dev-db.sh start')"
    fi
    if ! redis_installed; then
      echo "redis:    NINCS TELEPITVE   ($REDIS_SERVER nem letezik)"
    elif redis_running; then
      echo "redis:    UP   $("$REDIS_CLI" info server | /bin/grep -m1 redis_version | tr -d '\r')"
    else
      echo "redis:    ALL  (telepitve van, de nem fut -- 'dev-db.sh start')"
    fi
    ;;
  url)
    echo "DATABASE_URL=postgresql://$DEV_USER:$DEV_PASS@127.0.0.1:5432/$DEV_DB?schema=public"
    echo "REDIS_URL=redis://127.0.0.1:6379"
    ;;
  reset)
    # Both psql calls need sudo, and a caller WITHOUT sudo (any per-user agent)
    # gets "a password is required" on stderr -- while this branch used to print
    # "recreated" and exit 0 anyway. Measured 2026-08-22: an agent reset the
    # database, got exit 0, and the drop/create never ran; the following
    # migration deploy only looked clean because the database happened to be
    # empty already. A reset that cannot reset must FAIL, loudly.
    if ! sudo -n -u postgres psql -tAc "DROP DATABASE IF EXISTS $DEV_DB;"; then
      echo "reset FAILED: cannot run psql as postgres (need sudo). Nothing was dropped." >&2
      exit 1
    fi
    if ! sudo -n -u postgres psql -tAc "CREATE DATABASE $DEV_DB OWNER $DEV_USER;"; then
      echo "reset FAILED: the database was dropped but NOT recreated." >&2
      exit 1
    fi
    # Read it back: the create reporting success is not the same as the database
    # being there and connectable with the application's own credentials.
    if ! PGPASSWORD="$DEV_PASS" "$PG_BIN/psql" -h 127.0.0.1 -U "$DEV_USER" -d "$DEV_DB" -tAc "select 1;" >/dev/null 2>&1; then
      echo "reset FAILED: $DEV_DB does not answer as $DEV_USER after recreation." >&2
      exit 1
    fi
    echo "recreated $DEV_DB"
    ;;
  *)
    usage
    exit 1
    ;;
esac
