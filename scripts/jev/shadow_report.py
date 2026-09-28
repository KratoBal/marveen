#!/usr/bin/env python3
# ANSWERS: Mit mondott a Jev a D-005 shadow-ban, es mennyire egyezik a flotta sajat iteletevel (csak olvaso, szoveget soha nem ir ki)?
"""D-005 HIDDEN shadow evaluation report (read-only).

Reads three logs and never writes to them:
  store/jev-shadow.jsonl                 the shadow rows (shadow.py)
  store/outgoing-copy-gate-decisions.jsonl  the outgoing gate's own verdicts
  store/prior-art-recall.log             the recall hook's run log (tab separated)

NO TEXT EVER LEAVES THIS SCRIPT. Every string that reaches the output is a
constant of this file: a field value is printed only if it is on the
whitelist for that field, otherwise it becomes "<egyeb>". Numbers are
printed only if they are finite. The recall log's keyword column, the
decision log's hash and cwd, and the shadow row's input_hash are never read
into the report at all. This holds even if someone later puts text into a
log: the whitelist decides, not the log.

Usage:
  python3 shadow_report.py [--store DIR] [--since EPOCH|ISO] [--cold-ms 9000]
                           [--idle-s 300] [--window 10] [--out DIR]
Without --out the Markdown goes to stdout; with --out, shadow-report.md and
shadow-report.json are written into DIR (never into the store).
"""
import argparse
import datetime
import json
import math
import os
import sys

DEFAULT_STORE = "/home/marveen/marveen/store"

# ------------------------------------------------------------- whitelists
TASKS = ("memory", "outgoing")
OUTCOMES = ("provider_called", "disabled", "blocked_leak_gate", "blocked_redaction_error",
            "blocked_runtime_guard", "blocked_timeout", "blocked_too_long",
            "blocked_not_redacted", "bad_task", "error_before_call")
STORES = ("emlek", "naplo", "kartya", "komment", "csatorna", "eszkoz")
DIRECTIONS = ("in", "out")
VERDICTS = ("allow", "deny", "would-deny")
KINDS = ("DUPLA", "GONDOLATJEL", "HALASZTAS", "HELYTELEN", "HIANYZO", "MAGYAR", "VEGYES")
CHANNELS = ("Discord", "Telegram", "email")
QUESTIONS = ("rel", "defer", "reopen", "jargon", "multi")
CHOICES = ("RELEVANT", "NOT_RELEVANT", "UNCERTAIN", "YES", "NO")
PLACEHOLDERS = ("SECRET", "IBAN", "BANK_ACCOUNT", "TAX_ID", "EMAIL", "PHONE", "URL_QUERY",
                "ADDRESS", "PERSON", "ORG", "PROPER", "ID", "AMOUNT", "DATE", "HANDLE")
OTHER = "<egyeb>"
MISSING = "<nincs>"


def pick(value, allowed):
    """A whitelisted constant, never the input itself."""
    if value is None:
        return MISSING
    for a in allowed:
        if value == a:
            return a
    return OTHER


def _versionish(value, prefix, max_len=24):
    """'r9', 'jev-1.13.0', 'd005-shadow-v1': digits and dots after a fixed
    prefix, rebuilt from the digits so no input character is echoed."""
    if not isinstance(value, str) or not value.startswith(prefix) or len(value) > max_len:
        return MISSING if value is None else OTHER
    rest = value[len(prefix):]
    if not rest or any(c not in "0123456789." for c in rest):
        return OTHER
    return prefix + ".".join(str(int(p)) for p in rest.split(".") if p != "")


def num(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return value if math.isfinite(value) else None


def quantile(values, q):
    if not values:
        return None
    s = sorted(values)
    return s[max(0, min(len(s) - 1, math.ceil(q * len(s)) - 1))]


def iso(ts):
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ")


# ------------------------------------------------------------- readers
def read_jsonl(path):
    rows, bad = [], 0
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                if not line.strip():
                    continue
                try:
                    d = json.loads(line)
                except ValueError:
                    bad += 1
                    continue
                if isinstance(d, dict):
                    rows.append(d)
                else:
                    bad += 1
    except OSError:
        return None, 0
    return rows, bad


def shadow_rows(path, since):
    raw, bad = read_jsonl(path)
    if raw is None:
        return None, 0
    out = []
    for d in raw:
        ts = num(d.get("ts"))
        if ts is None or ts < since:
            continue
        local = d.get("local") if isinstance(d.get("local"), dict) else {}
        answers = {}
        if isinstance(d.get("answers"), dict):
            for q, a in d["answers"].items():
                q2 = pick(q, QUESTIONS)
                if q2 in (OTHER, MISSING) or not isinstance(a, dict):
                    continue
                answers[q2] = (pick(a.get("choice"), CHOICES), num(a.get("confidence")))
        ph = {}
        if isinstance(d.get("placeholders"), dict):
            for k, v in d["placeholders"].items():
                n = num(v)
                if n is not None:
                    k2 = pick(k, PLACEHOLDERS)
                    ph[k2] = ph.get(k2, 0) + n
        kinds = local.get("kinds") if isinstance(local.get("kinds"), list) else []
        out.append({
            "ts": ts,
            "task": pick(d.get("task"), TASKS),
            "outcome": pick(d.get("outcome"), OUTCOMES),
            "policy": _versionish(d.get("policy"), "d005-shadow-v"),
            "redaction": _versionish(d.get("redaction_version"), "r"),
            "model": _versionish(d.get("model"), "jev-"),
            "latency": num(d.get("latency_ms")),
            "tokens": num(d.get("input_tokens")),
            "answers": answers,
            "placeholders": ph,
            "shown": local.get("shown") if isinstance(local.get("shown"), bool) else None,
            "store": pick(local.get("store"), STORES),
            "direction": pick(local.get("direction"), DIRECTIONS),
            "rank": num(local.get("rank")),
            "score": num(local.get("score")),
            "verdict": pick(local.get("verdict"), VERDICTS),
            "kinds": sorted({pick(k, KINDS) for k in kinds}),
            "channel": pick(local.get("channel"), CHANNELS),
        })
    return out, bad


def decision_rows(path, since):
    raw, bad = read_jsonl(path)
    if raw is None:
        return None, 0
    out = []
    for d in raw:
        ts = num(d.get("ts"))
        if ts is None or ts < since:
            continue
        kinds = d.get("kinds") if isinstance(d.get("kinds"), list) else []
        out.append({"ts": ts, "channel": pick(d.get("channel"), CHANNELS),
                    "verdict": pick(d.get("verdict"), VERDICTS),
                    "kinds": sorted({pick(str(k).split()[0] if str(k).split() else "", KINDS)
                                     for k in kinds}),
                    "len": num(d.get("len"))})
    return out, bad


def recall_rows(path, since):
    """Only the 6-column lines (after the 2026-09-28 extension). The keyword
    column (index 1) is skipped on purpose and never stored."""
    out, bad, old = [], 0, 0
    try:
        f = open(path, encoding="utf-8", errors="replace")
    except OSError:
        return None, 0, 0
    with f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) == 3:
                old += 1
                continue
            if len(parts) != 6:
                bad += 1
                continue
            try:
                ts = datetime.datetime.strptime(parts[0], "%Y-%m-%d %H:%M:%S").timestamp()
                hits, chars, brake = int(parts[2]), int(parts[3]), int(parts[5])
            except ValueError:
                bad += 1
                continue
            if ts < since:
                continue
            out.append({"ts": ts, "hits": hits, "chars": chars,
                        "direction": pick(parts[4], DIRECTIONS), "brake": brake == 1})
    return out, bad, old


# ------------------------------------------------------------- analysis
def dist(values):
    d = {}
    for v in values:
        d[v] = d.get(v, 0) + 1
    return dict(sorted(d.items(), key=lambda x: (-x[1], str(x[0]))))


def stats(values):
    v = [x for x in values if x is not None]
    if not v:
        return {"n": 0}
    return {"n": len(v), "p50": quantile(v, 0.5), "p95": quantile(v, 0.95),
            "max": max(v), "sum": sum(v), "mean": round(sum(v) / len(v), 1)}


def _nearest(rows, ts, window, pred=lambda r: True):
    best = None
    for r in rows:
        d = abs(r["ts"] - ts)
        if d <= window and pred(r) and (best is None or d < abs(best["ts"] - ts)):
            best = r
    return best


def analyse(shadow, decisions, recall, cold_ms, match_window, idle_s=300):
    rep = {"rows": len(shadow)}
    if shadow:
        ts = [r["ts"] for r in shadow]
        rep["window"] = [iso(min(ts)), iso(max(ts))]
    rep["by_task"] = {}
    for task in TASKS + (OTHER, MISSING):
        rows = [r for r in shadow if r["task"] == task]
        if not rows:
            continue
        outcomes = dist(r["outcome"] for r in rows)
        active = [r for r in rows if r["outcome"] != "disabled"]
        blocked = [r for r in active if r["outcome"].startswith("blocked_")]
        called = [r for r in rows if r["outcome"] == "provider_called"]
        cold = [r for r in called if r["latency"] is not None and r["latency"] >= cold_ms]
        warm = [r for r in called if r["latency"] is not None and r["latency"] < cold_ms]
        ph_tot = {}
        for r in called:
            for k, v in r["placeholders"].items():
                ph_tot[k] = ph_tot.get(k, 0) + v
        t = {
            "rows": len(rows),
            "outcomes": outcomes,
            "provider_called": len(called),
            # P-016 (d005-shadow-v2): one call writes one row per candidate and
            # carries latency/tokens on the first row only -- so a call is a row
            # with a latency. Under v1 every row is its own call.
            "calls": sum(1 for r in called if r["latency"] is not None),
            "blocked_share_of_active": (round(len(blocked) / len(active), 4) if active else None),
            "errors": sum(1 for r in rows if r["outcome"] == "error_before_call"),
            "redaction_versions": dist(r["redaction"] for r in rows),
            "models": dist(r["model"] for r in called),
            "policies": dist(r["policy"] for r in rows),
            "placeholders_total": dict(sorted(ph_tot.items(), key=lambda x: -x[1])),
            "placeholders_per_call": (round(sum(ph_tot.values()) / len(called), 2) if called else None),
            "calls_without_placeholder": sum(1 for r in called if not r["placeholders"]),
            "latency_warm": stats([r["latency"] for r in warm]),
            "latency_all": stats([r["latency"] for r in called]),
            "cold_calls": [{"time": iso(r["ts"]), "ms": r["latency"]} for r in sorted(cold, key=lambda r: r["ts"])][:20],
            "cold_count": len(cold),
            "tokens": stats([r["tokens"] for r in called]),
        }
        if task == "memory":
            t["agreement"] = memory_agreement(called, recall, match_window)
        if task == "outgoing":
            t["agreement"] = outgoing_agreement(called)
            t["coverage"] = coverage(rows, decisions, match_window)
        rep["by_task"][task] = t
    rep["timing"] = timing([r for r in shadow if r["outcome"] == "provider_called"], cold_ms, idle_s)
    rep["recall_log"] = recall_summary(recall)
    return rep


def memory_agreement(called, recall, window):
    """Jev 'rel' against the fleet's own choice: was the hit shown (in the
    printed block) or not. Plus the outgoing brake as a second signal."""
    tab = {}
    for r in called:
        choice = r["answers"].get("rel", (MISSING, None))[0]
        key = (choice, "shown" if r["shown"] is True else "not_shown" if r["shown"] is False else MISSING)
        tab[key] = tab.get(key, 0) + 1

    def rate(rows):
        rows = [r for r in rows if "rel" in r["answers"]]
        if not rows:
            return None
        return {"n": len(rows), "relevant": sum(1 for r in rows if r["answers"]["rel"][0] == "RELEVANT")}

    by_rank = {}
    for lo, hi, name in ((1, 2, "1-2"), (3, 4, "3-4"), (5, 8, "5-8")):
        by_rank[name] = rate([r for r in called if r["rank"] is not None and lo <= r["rank"] <= hi])
    brake = {"matched": 0, "unmatched": 0, "brake_on": None, "brake_off": None}
    on, off = [], []
    if recall is not None:
        for r in called:
            if r["direction"] != "out":
                continue
            m = _nearest(recall, r["ts"], window, lambda x: x["direction"] == "out")
            if m is None:
                brake["unmatched"] += 1
                continue
            brake["matched"] += 1
            (on if m["brake"] else off).append(r)
        brake["brake_on"], brake["brake_off"] = rate(on), rate(off)
    return {
        "table": [{"jev": k[0], "local": k[1], "n": v} for k, v in sorted(tab.items())],
        "shown": rate([r for r in called if r["shown"] is True]),
        "not_shown": rate([r for r in called if r["shown"] is False]),
        "by_direction": {d: rate([r for r in called if r["direction"] == d]) for d in DIRECTIONS},
        "by_store": {s: rate([r for r in called if r["store"] == s]) for s in STORES + (OTHER,)
                     if any(r["store"] == s for r in called)},
        "by_rank": by_rank,
        "brake": brake,
    }


def outgoing_agreement(called):
    """Each Jev question against the local verdict; 'defer' also against the
    local HALASZTAS kind, which is its rule-based twin."""
    per_q = {}
    for q in ("defer", "reopen", "jargon", "multi"):
        tab = {}
        for r in called:
            if q not in r["answers"]:
                continue
            local = "stopped" if r["verdict"] in ("deny", "would-deny") else r["verdict"]
            key = (r["answers"][q][0], local)
            tab[key] = tab.get(key, 0) + 1
        per_q[q] = [{"jev": k[0], "local": k[1], "n": v} for k, v in sorted(tab.items())]
    defer = {}
    for r in called:
        if "defer" not in r["answers"]:
            continue
        key = (r["answers"]["defer"][0], "HALASZTAS" if "HALASZTAS" in r["kinds"] else "nincs")
        defer[key] = defer.get(key, 0) + 1
    return {
        "per_question_vs_verdict": per_q,
        "defer_vs_HALASZTAS": [{"jev": k[0], "local": k[1], "n": v} for k, v in sorted(defer.items())],
        "local_verdicts": dist(r["verdict"] for r in called),
        "local_kinds": dist(k for r in called for k in r["kinds"]),
        "channels": dist(r["channel"] for r in called),
    }


def coverage(rows, decisions, window):
    """How many chat-channel gate decisions got a shadow row at all. A
    decision without one is a lost measurement (child died, switch off...)."""
    if decisions is None:
        return None
    chat = [d for d in decisions if d["channel"] in ("Discord", "Telegram")]
    if rows:
        start = min(r["ts"] for r in rows) - window
        chat = [d for d in chat if d["ts"] >= start]
    # ONE-TO-ONE: a shadow row answers at most one decision. Without this, two
    # decisions a few seconds apart would both count the same row as theirs.
    free = list(rows)
    matched = 0
    for d in sorted(chat, key=lambda x: x["ts"]):
        m = _nearest(free, d["ts"], window, lambda r: r["channel"] == d["channel"])
        if m is not None:
            free.remove(m)
            matched += 1
    return {"chat_decisions": len(chat), "with_shadow_row": matched,
            "without_shadow_row": len(chat) - matched,
            "decision_verdicts": dist(d["verdict"] for d in chat)}


# A NEGATIVE idle is not a short pause: a call from an earlier second was still
# RUNNING when this one started. It gets its own bucket, never "<10 s".
IDLE_BUCKETS = ((float("-inf"), 0, "átfedés"), (0, 10, "<10 s"), (10, 60, "10-60 s"), (60, 300, "1-5 perc"),
                (300, 1800, "5-30 perc"), (1800, None, ">=30 perc"), (None, None, "első hívás"))
# Half-open like the idle buckets: [lo, hi).
BURST_BUCKETS = ((1, 2, "1"), (2, 4, "2-3"), (4, 9, "4-8"), (9, None, "9+"))


def _bucket(value, buckets):
    for lo, hi, name in buckets:
        if lo is None:
            return name if value is None else None
        if value is not None and value >= lo and (hi is None or value < hi):
            return name
    return None


def timing(called, cold_ms, idle_s):
    """WHY A CALL WAS SLOW. Three explanations, and each has its own fix:
      the provider fell asleep     -> an occasional wake-up call
      too many calls at once       -> queueing or less parallelism
      neither                      -> look at the connection (every detached
                                      child opens its own TLS connection)

    Per call, across BOTH tasks (they share the provider):
      idle_before  seconds since the latest call from an EARLIER second ended
                   (<=0: it was still running); a same-second burst shares it
      same_second  calls whose job started in the same second
      in_flight    calls running at this call's start, itself included

    The row's ts is the job start in whole seconds and latency_ms times the
    provider call alone, so start ~ ts and end ~ ts + latency: a resolution
    of one second, which is enough to tell a 10-minute pause from a burst.

    The decisive table is 2x2: long idle or not, times alone or in a burst.
    A burst right after a long pause cannot tell the first two apart; a
    lone call after a pause, and a burst after no pause, can."""
    calls = sorted((r for r in called if r["latency"] is not None), key=lambda r: r["ts"])
    per_second = {}
    for r in calls:
        per_second[int(r["ts"])] = per_second.get(int(r["ts"]), 0) + 1
    max_lat = max((r["latency"] for r in calls), default=0) / 1000
    # latest_end covers calls from EARLIER seconds only: a burst is one event,
    # and its members must not measure their pause against each other.
    rows, latest_end, second_end, second = [], None, None, None
    for i, r in enumerate(calls):
        start = r["ts"]
        if int(start) != second:
            if second_end is not None:
                latest_end = second_end if latest_end is None else max(latest_end, second_end)
            second, second_end = int(start), None
        idle = None if latest_end is None else start - latest_end
        # Only EARLIER calls can be running at this start (the list is sorted);
        # a call that started in the same second but earlier in the log counts.
        in_flight, j = 1, i - 1
        while j >= 0 and calls[j]["ts"] >= start - max_lat:
            e = calls[j]
            if e["ts"] <= start < e["ts"] + e["latency"] / 1000:
                in_flight += 1
            j -= 1
        end = start + r["latency"] / 1000
        second_end = end if second_end is None else max(second_end, end)
        rows.append({"ts": start, "task": r["task"], "ms": r["latency"], "cold": r["latency"] >= cold_ms,
                     "idle": idle, "same_second": per_second[int(start)], "in_flight": in_flight})

    def cell(sel):
        n = len(sel)
        c = sum(1 for x in sel if x["cold"])
        return {"n": n, "cold": c}

    long_idle = lambda x: x["idle"] is None or x["idle"] >= idle_s
    burst = lambda x: x["same_second"] > 1 or x["in_flight"] > 1
    grid = {
        "hosszú_szünet_egyedül": cell([x for x in rows if long_idle(x) and not burst(x)]),
        "hosszú_szünet_csomagban": cell([x for x in rows if long_idle(x) and burst(x)]),
        "rövid_szünet_egyedül": cell([x for x in rows if not long_idle(x) and not burst(x)]),
        "rövid_szünet_csomagban": cell([x for x in rows if not long_idle(x) and burst(x)]),
    }
    by_idle = {}
    for _, _, name in IDLE_BUCKETS:
        sel = [x for x in rows if _bucket(x["idle"], IDLE_BUCKETS) == name]
        if sel:
            by_idle[name] = cell(sel)
    by_burst = {}
    for _, _, name in BURST_BUCKETS:
        sel = [x for x in rows if _bucket(x["same_second"], BURST_BUCKETS) == name]
        if sel:
            by_burst[name] = cell(sel)
    by_inflight = {}
    for _, _, name in BURST_BUCKETS:
        sel = [x for x in rows if _bucket(x["in_flight"], BURST_BUCKETS) == name]
        if sel:
            by_inflight[name] = cell(sel)
    return {
        "calls": len(rows),
        "idle_threshold_s": idle_s,
        "grid": grid,
        "by_idle": by_idle,
        "by_same_second": by_burst,
        "by_in_flight": by_inflight,
        "cold_calls": [{"time": iso(x["ts"]), "task": x["task"], "ms": x["ms"],
                        "idle_s": None if x["idle"] is None else round(x["idle"], 1),
                        "overlap": x["idle"] is not None and x["idle"] < 0,
                        "same_second": x["same_second"], "in_flight": x["in_flight"]}
                       for x in rows if x["cold"]][:40],
    }


def recall_summary(recall):
    if recall is None:
        return None
    return {d: {"runs": sum(1 for r in recall if r["direction"] == d),
                "brake": sum(1 for r in recall if r["direction"] == d and r["brake"]),
                "chars": stats([r["chars"] for r in recall if r["direction"] == d]),
                "hits": stats([r["hits"] for r in recall if r["direction"] == d])}
            for d in DIRECTIONS}


# ------------------------------------------------------------- output
def _pct(n, d):
    return "–" if not d else f"{100 * n / d:.1f}%"


def _idle_text(x):
    if x["idle_s"] is None:
        return "első hívás"
    if x["overlap"]:
        return f"átfedés {-x['idle_s']} s (előző még futott)"
    return f"szünet {x['idle_s']} s"


def _share(x):
    return "–" if x is None else f"{100 * x:.1f}%"


def _rate(r):
    return "–" if not r else f"{r['relevant']}/{r['n']} ({_pct(r['relevant'], r['n'])})"


def _st(s, unit=""):
    if not s or not s.get("n"):
        return "–"
    return f"n={s['n']}, p50 {s['p50']}{unit}, p95 {s['p95']}{unit}, max {s['max']}{unit}"


def _d(d):
    return ", ".join(f"{k} {v}" for k, v in d.items()) or "–"


def markdown(rep, meta):
    L = ["# D-005 shadow kiértékelés", "",
         f"- olvasva: shadow {meta['shadow']}, döntésnapló {meta['decisions']}, recall-napló {meta['recall']}",
         f"- időablak: {' – '.join(rep['window']) if rep.get('window') else 'nincs sor'}"
         f"; sorok: {rep['rows']}, hibás sor: {meta['bad_shadow']}",
         f"- hidegindulás küszöbe: {meta['cold_ms']} ms; párosítási ablak: ±{meta['window']} s", ""]
    for task, t in rep["by_task"].items():
        L += [f"## {task}", "",
              f"- kimenetel: {_d(t['outcomes'])}",
              f"- szolgáltatóhoz ment: {t['provider_called']} sor, {t['calls']} hívás; blokk-arány a nem kikapcsolt sorokon: "
              f"{_share(t['blocked_share_of_active'])}; hiba a hívás előtt vagy közben: {t['errors']}",
              f"- kitakaró-verzió: {_d(t['redaction_versions'])}; modell: {_d(t['models'])}; policy: {_d(t['policies'])}",
              f"- helyőrzők összesen: {_d(t['placeholders_total'])}; hívásonként {t['placeholders_per_call']}; helyőrző nélküli hívás: {t['calls_without_placeholder']}",
              f"- késleltetés (meleg, < küszöb): {_st(t['latency_warm'], ' ms')}",
              f"- késleltetés (összes): {_st(t['latency_all'], ' ms')}",
              f"- **hidegindulás (≥ küszöb): {t['cold_count']} hívás**"
              + ("" if not t["cold_calls"] else ": " + ", ".join(f"{c['time']} {c['ms']} ms" for c in t["cold_calls"])),
              f"- bemeneti token: {_st(t['tokens'])}"
              + (f", összesen {t['tokens']['sum']}" if t["tokens"].get("n") else ""), ""]
        a = t.get("agreement")
        if task == "memory" and a:
            L += ["### Egyezés: Jev `rel` kontra a flotta (megjelent-e a találat)", "",
                  "| Jev | helyi | db |", "|---|---|---|"]
            L += [f"| {x['jev']} | {x['local']} | {x['n']} |" for x in a["table"]]
            b = a["brake"]
            L += ["",
                  f"- RELEVANT a megjelent találatokon: {_rate(a['shown'])}; a nem megjelenteken: {_rate(a['not_shown'])}",
                  f"- irány szerint: " + ", ".join(f"{k} {_rate(v)}" for k, v in a["by_direction"].items()),
                  f"- tároló szerint: " + (", ".join(f"{k} {_rate(v)}" for k, v in a["by_store"].items()) or "–"),
                  f"- rang szerint: " + ", ".join(f"{k} {_rate(v)}" for k, v in a["by_rank"].items()),
                  f"- kimenő fék (recall-napló, párosítva {b['matched']}, párosítatlan {b['unmatched']}): "
                  f"fékezett futásban {_rate(b['brake_on'])}, fék nélkül {_rate(b['brake_off'])}", ""]
        if task == "outgoing" and a:
            L += ["### Egyezés: Jev kérdések kontra a kapu ítélete", ""]
            for q, rows in a["per_question_vs_verdict"].items():
                L.append(f"- `{q}`: " + (", ".join(f"Jev {x['jev']} / helyi {x['local']}: {x['n']}" for x in rows) or "–"))
            L += [f"- `defer` kontra a helyi HALASZTAS szabály: "
                  + (", ".join(f"Jev {x['jev']} / helyi {x['local']}: {x['n']}" for x in a["defer_vs_HALASZTAS"]) or "–"),
                  f"- helyi ítélet: {_d(a['local_verdicts'])}; helyi szabály-fajták: {_d(a['local_kinds'])}; csatorna: {_d(a['channels'])}"]
            c = t.get("coverage")
            if c:
                L.append(f"- lefedettség: a csatorna-döntésekből {c['with_shadow_row']}/{c['chat_decisions']} kapott shadow-sort"
                         f" ({c['without_shadow_row']} nem); a döntések ítélete: {_d(c['decision_verdicts'])}")
            L.append("")
    tm = rep.get("timing")
    if tm and tm["calls"]:
        g = tm["grid"]

        def c(x):
            return f"{x['cold']}/{x['n']} ({_pct(x['cold'], x['n'])})" if x["n"] else "–"
        L += ["## Miért lassú egy hívás: alvás, egyidejűség vagy egyik sem", "",
              f"Mindkét feladat hívásai együtt ({tm['calls']}), mert ugyanazt a szolgáltatót terhelik. "
              f"Hosszú szünet: legalább {tm['idle_threshold_s']} s az előző hívás vége óta (vagy az első hívás). "
              "Csomag: ugyanabban a másodpercben több indult, vagy induláskor másik hívás még futott. "
              "Átfedés: egy korábbi másodpercben indult hívás még futott (negatív szünet, külön sáv). "
              "Felbontás: 1 s.", "",
              "| hideg / összes | egyedül | csomagban |", "|---|---|---|",
              f"| hosszú szünet után | {c(g['hosszú_szünet_egyedül'])} | {c(g['hosszú_szünet_csomagban'])} |",
              f"| rövid szünet után | {c(g['rövid_szünet_egyedül'])} | {c(g['rövid_szünet_csomagban'])} |", "",
              "Olvasat: ha csak a hosszú szünet sora hideg, a szolgáltató alszik el (ritka ébresztő hívás). "
              "Ha csak a csomag oszlopa, az egyidejűség (sorba állítás vagy kisebb párhuzamosság). "
              "Ha a rövid szünet utáni egyedüli hívás is gyakran hideg, egyik sem: a kapcsolatnyitást kell nézni. "
              "A hosszú szünet utáni csomag cellája egyedül nem dönt.", "",
              "- tétlen idő szerint: " + ", ".join(f"{k} {c(v)}" for k, v in tm["by_idle"].items()),
              "- ugyanabban a másodpercben indult: " + ", ".join(f"{k} {c(v)}" for k, v in tm["by_same_second"].items()),
              "- induláskor futó hívások (magával együtt): " + ", ".join(f"{k} {c(v)}" for k, v in tm["by_in_flight"].items()),
              "- hideg hívások: " + ("; ".join(
                  f"{x['time']} {x['task']} {x['ms']} ms, {_idle_text(x)}, "
                  f"egy másodpercben {x['same_second']}, futó {x['in_flight']}" for x in tm["cold_calls"]) or "nincs"), ""]
    rs = rep.get("recall_log")
    if rs:
        L += ["## Recall-napló (az új, 6 oszlopos sorok)", ""]
        for d, s in rs.items():
            L.append(f"- {d}: futás {s['runs']}, fék {s['brake']}; karakter {_st(s['chars'])}; találat {_st(s['hits'])}")
        L.append("")
    L.append("A riport szöveget nem tartalmaz: minden érték a szkript saját fehérlistájáról vagy szám.")
    return "\n".join(L) + "\n"


def parse_since(v):
    if v is None:
        return 0
    try:
        return float(v)
    except ValueError:
        return datetime.datetime.fromisoformat(v).timestamp()


def main(argv=None):
    ap = argparse.ArgumentParser(description="D-005 shadow evaluation (read-only)")
    ap.add_argument("--store", default=os.environ.get("JEV_STORE", DEFAULT_STORE))
    ap.add_argument("--since")
    ap.add_argument("--cold-ms", type=int, default=9000)
    ap.add_argument("--window", type=int, default=10, help="matching window in seconds")
    ap.add_argument("--idle-s", type=int, default=300, help="a pause at least this long counts as idle")
    ap.add_argument("--out")
    a = ap.parse_args(argv)
    try:
        since = parse_since(a.since)
    except ValueError:
        print("érvénytelen --since", file=sys.stderr)
        return 1
    sp = os.path.join(a.store, "jev-shadow.jsonl")
    dp = os.path.join(a.store, "outgoing-copy-gate-decisions.jsonl")
    rp = os.path.join(a.store, "prior-art-recall.log")
    shadow, bad_s = shadow_rows(sp, since)
    decisions, _ = decision_rows(dp, since)
    recall, _, _ = recall_rows(rp, since)
    if shadow is None:
        print("a shadow-napló nem olvasható: " + ("nincs ilyen fájl" if not os.path.exists(sp) else "jogosultság"),
              file=sys.stderr)
        return 2
    rep = analyse(shadow, decisions, recall, a.cold_ms, a.window, a.idle_s)
    meta = {"shadow": "ok", "decisions": "ok" if decisions is not None else "nem olvasható",
            "recall": "ok" if recall is not None else "nem olvasható", "bad_shadow": bad_s,
            "cold_ms": a.cold_ms, "window": a.window, "idle_s": a.idle_s}
    md = markdown(rep, meta)
    if a.out:
        os.makedirs(a.out, exist_ok=True)
        with open(os.path.join(a.out, "shadow-report.md"), "w", encoding="utf-8") as f:
            f.write(md)
        with open(os.path.join(a.out, "shadow-report.json"), "w", encoding="utf-8") as f:
            json.dump({"meta": meta, "report": rep}, f, ensure_ascii=False, indent=1)
        print(os.path.join(a.out, "shadow-report.md"))
    else:
        sys.stdout.write(md)
    return 0


if __name__ == "__main__":
    sys.exit(main())
