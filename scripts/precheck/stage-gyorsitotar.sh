#!/usr/bin/env bash
# ANSWERS: Kell-e felebreszteni a stage-gyorsitotar-orjarat heartbeatet (van-e mit takaritani vagy jelezni a teszt gepen)?
#
# Scheduler preCheck (D-004, Balazs 2026-09-28 12:52 UTC). SKIP only when the
# task's own "do nothing, write nothing" branch holds: Build Cache RECLAIMABLE
# (docker system df, not builder du) under 2 GB AND the disk under 80 percent.
# Every other case wakes the agent with the measurement as a prefix, including
# an unreachable host: ssh failure exits non-zero and the runner fails open.
# The runner kills this after 10 s, so the ssh timeouts stay under that.
m=$(timeout 8 ssh -o BatchMode=yes -o ConnectTimeout=5 -i /home/marveen/.ssh/id_ed25519_acropora_monitor fleet@100.88.199.87 "df -P / | tail -1; docker system df --format '{{.Type}}|{{.Size}}|{{.Reclaimable}}'") || exit 1
printf '%s\n' "$m" | python3 -c '
import re, sys
lines = sys.stdin.read().splitlines()
units = {"B": 1, "kB": 1e3, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12}
def size(v):
    m = re.match(r"\s*([\d.]+)\s*([kKMGT]?B)", v)
    if not m: raise SystemExit(1)
    return float(m.group(1)) * units[m.group(2)]
disk = cache = None
for l in lines:
    if l.startswith("Build Cache|"): cache = size(l.split("|")[2])
    elif "%" in l and not "|" in l: disk = int(re.search(r"(\d+)%", l).group(1))
if disk is None or cache is None: raise SystemExit(1)
if cache < 2e9 and disk < 80: print("SKIP")
else: print("[preCheck meres] lemez %d%%, Build Cache visszanyerheto %.2f GB" % (disk, cache / 1e9))
'
