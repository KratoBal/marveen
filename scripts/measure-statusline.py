#!/usr/bin/env python3
# ANSWERS: Mennyi a Claude elofizetes 5 oras es heti keretebol felhasznalva, PONTOSAN (nem becsles) -- statusline-kent fut, es mintat ir.
"""
measure-statusline.py -- Claude Code statusLine command that doubles as the
fleet's quota sampler (Measurement Layer v1).

Why here and not scripts/usage-collect.py: the authoritative endpoint that
script calls (api.anthropic.com/api/oauth/usage) answers 403 to the fleet's
setup-token (measured 2026-09-27). Claude Code itself hands the statusline a
`rate_limits` object (five_hour / seven_day used_percentage + resets_at) once
the session has made one API call. That is the same number the TUI prints as
"You've used N% of your weekly limit".

Behaviour:
  * reads the statusline JSON on stdin,
  * if rate_limits is present and the newest sample is >= 300 s old, appends
    ONE line to store/measurements/quota-samples.jsonl (append-only, one
    write() per line, so a crash leaves at most one torn line that the
    ingester skips),
  * prints a one-line status (model, 5h %, 7d %).

It never records the transcript path, cwd, session id or anything
credential-shaped: only numbers, the model id and the agent name.
Stdlib only. Must never fail the statusline: every error path still prints.
"""
import json
import os
import sys
import time

MIN_INTERVAL_S = 300
ROOT = os.environ.get("MARVEEN_ROOT", "/home/marveen/marveen")
OUT = os.environ.get("MEASURE_QUOTA_FILE", os.path.join(ROOT, "store", "measurements", "quota-samples.jsonl"))


def pct(block):
    if isinstance(block, dict):
        v = block.get("used_percentage")
        if isinstance(v, (int, float)):
            return v
    return None


def resets(block):
    if isinstance(block, dict):
        v = block.get("resets_at")
        if isinstance(v, (int, float)):
            return int(v)
    return None


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        print("statusline: no input")
        return
    model = (data.get("model") or {}).get("id") if isinstance(data.get("model"), dict) else None
    rl = data.get("rate_limits") if isinstance(data.get("rate_limits"), dict) else None
    five = pct(rl.get("five_hour")) if rl else None
    seven = pct(rl.get("seven_day")) if rl else None

    if rl and (five is not None or seven is not None):
        now = int(time.time())
        try:
            fresh = os.path.exists(OUT) and now - int(os.stat(OUT).st_mtime) < MIN_INTERVAL_S
        except OSError:
            fresh = False
        if not fresh:
            line = json.dumps({
                "sampled_at": now,
                "source": "claude-code-statusline",
                "agent": os.environ.get("MEASURE_AGENT") or None,
                "model": model,
                "five_hour_pct": five,
                "five_hour_resets_at": resets(rl.get("five_hour")),
                "seven_day_pct": seven,
                "seven_day_resets_at": resets(rl.get("seven_day")),
            }, separators=(",", ":")) + "\n"
            try:
                os.makedirs(os.path.dirname(OUT), exist_ok=True)
                fd = os.open(OUT, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o664)
                try:
                    os.write(fd, line.encode("utf-8"))
                finally:
                    os.close(fd)
            except OSError:
                pass

    parts = [model or "?"]
    parts.append("5h " + (f"{five:g}%" if five is not None else "?"))
    parts.append("7d " + (f"{seven:g}%" if seven is not None else "?"))
    print(" | ".join(parts))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        print("statusline: error")
