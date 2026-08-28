#!/usr/bin/env bash
# Local development database for the fleet container.
#
# Why this exists: the acropora-os working copies carry a .env whose
# DATABASE_URL points at the LIVE database, so "just run the app" is not a
# safe instruction. This script runs a PostgreSQL 16 (same major version the
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

pg_running() { sudo -u postgres "$PG_BIN/pg_isready" -q -h 127.0.0.1 2>/dev/null; }
redis_running() { redis-cli ping >/dev/null 2>&1; }

case "${1:-}" in
  start)
    pg_running || sudo pg_ctlcluster 16 main start
    redis_running || sudo redis-server /etc/redis/redis.conf --daemonize yes
    sleep 1
    "$0" status
    ;;
  stop)
    sudo pg_ctlcluster 16 main stop || true
    redis-cli shutdown nosave >/dev/null 2>&1 || true
    echo "stopped"
    ;;
  status)
    if pg_running; then
      echo "postgres: UP   $(sudo -u postgres psql -tAc 'select version();' | cut -d, -f1)"
    else
      echo "postgres: DOWN"
    fi
    if redis_running; then
      echo "redis:    UP   $(redis-cli info server | /bin/grep -m1 redis_version | tr -d '\r')"
    else
      echo "redis:    DOWN"
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
