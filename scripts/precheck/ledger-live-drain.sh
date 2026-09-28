#!/usr/bin/env bash
# ANSWERS: Kell-e egyaltalan felebreszteni a ledger-live-drain heartbeatet (van-e megvalaszolatlan bejovo)?
#
# Scheduler preCheck (D-004, Balazs 2026-09-28 12:52 UTC). The runner runs this
# with bash before waking the agent: stdout "SKIP" = no wake, no model turn;
# anything else (or a non-zero exit, or a timeout) = wake as before (fail-open).
# The drain answers empty on almost every tick, and each wake is a full turn.
cd /home/marveen/marveen || exit 1
out=$(python3 /home/marveen/marveen/scripts/hooks/ledger-live-drain.py --peek) || exit 1
[ -z "$out" ] && echo SKIP
exit 0
