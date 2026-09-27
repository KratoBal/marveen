#!/usr/bin/env python3
"""Read-only SQL helper for the nightly dream-engine task.

WHY THIS EXISTS: the dream-engine SKILL.md used to spell its queries as `sqlite3 ...`
shell calls, and the `sqlite3` CLI is NOT installed here (the installer's dependencies
are ffmpeg, git, tmux, lsof, curl, python3, pipx, unzip). The 2026-08-18 02:11 run got
its numbers anyway -- the agent noticed and reimplemented every query with python3's
sqlite3 module on the fly -- but it also wrote "`sqlite3` CLI nincs telepitve" into the
report's error section every single night. That is noise about our own instructions,
not a finding about the fleet, and it cost a full improvisation round per run.

READ-ONLY BY CONSTRUCTION: the database is opened in SQLite read-only mode, so a typo
here cannot mutate the fleet's memory. Tier moves (hot -> cold) go through the dashboard
API instead (PUT /api/memories/<id>), which keeps the app's caches coherent -- a direct
UPDATE would leave the in-process memory cache serving the old tier.

Usage:
  python3 scripts/dream-query.py memories-24h        # today's hot/warm memories, per agent
  python3 scripts/dream-query.py memory-stats        # total / embedded / per-tier counts
  python3 scripts/dream-query.py stale-hot [days]    # hot memories untouched for N days (default 7)
  python3 scripts/dream-query.py duplicates          # exact duplicate contents
  python3 scripts/dream-query.py kanban-open         # open cards by project and priority
  python3 scripts/dream-query.py skill-usage         # skill_usage rows (empty table is itself a finding)

Output is TSV with a header line, so it stays readable in the report and greppable here.
"""
import os
import sqlite3
import sys

DB = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'store', 'claudeclaw.db')


def rows(sql, params=()):
    # mode=ro: the file is opened read-only; a stray UPDATE raises instead of writing.
    con = sqlite3.connect('file:' + DB + '?mode=ro', uri=True)
    try:
        cur = con.execute(sql, params)
        return [d[0] for d in cur.description], cur.fetchall()
    finally:
        con.close()


def emit(header, data):
    print('\t'.join(header))
    for r in data:
        print('\t'.join('' if v is None else str(v).replace('\t', ' ').replace('\n', ' ') for v in r))
    print(f'# {len(data)} sor', file=sys.stderr)


QUERIES = {
    'memories-24h': (
        "SELECT agent_id, category, content, keywords FROM memories "
        "WHERE created_at > strftime('%s','now','-24 hours') AND category IN ('hot','warm') "
        "ORDER BY agent_id, created_at", ()),
    'memory-stats': (
        "SELECT category, COUNT(*) AS db, COUNT(embedding) AS embeddelt FROM memories "
        "GROUP BY category ORDER BY category", ()),
    'duplicates': (
        "SELECT content, COUNT(*) AS db, GROUP_CONCAT(id) AS ids FROM memories "
        "GROUP BY content HAVING COUNT(*) > 1 ORDER BY db DESC", ()),
    'kanban-open': (
        "SELECT id, title, status, project, priority, assignee FROM kanban_cards "
        "WHERE status IN ('planned','in_progress','waiting') AND archived_at IS NULL "
        "ORDER BY project, priority DESC", ()),
    'skill-usage': ("SELECT * FROM skill_usage ORDER BY rowid DESC LIMIT 200", ()),
}


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in QUERIES and sys.argv[1] != 'stale-hot':
        print(__doc__)
        return 2
    cmd = sys.argv[1]
    if cmd == 'stale-hot':
        days = sys.argv[2] if len(sys.argv) > 2 else '7'
        if not days.isdigit():
            print('FAIL: a napok szama egesz szam legyen', file=sys.stderr)
            return 1
        sql = ("SELECT id, agent_id, content, accessed_at FROM memories "
               "WHERE category='hot' AND accessed_at < strftime('%s','now','-" + days + " days') "
               "ORDER BY accessed_at")
        params = ()
    else:
        sql, params = QUERIES[cmd]
    try:
        header, data = rows(sql, params)
    except sqlite3.OperationalError as e:
        # A missing table is a real finding for the report (e.g. skill_usage never created),
        # not a crash to swallow silently.
        print(f'FAIL: {e}', file=sys.stderr)
        return 1
    emit(header, data)
    return 0


if __name__ == '__main__':
    sys.exit(main())
