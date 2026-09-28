"""D-005 shadow report: the numbers, and the one hard rule -- no text out.

Every fixture row is invented; the shapes follow acrobot's real rows of
2026-09-28 (hash replaced). No network, no real store."""
import contextlib
import io
import json
import os
import sys
import tempfile
import time
import unittest

# Runs both next to the module and from scripts/jev/tests/ (the module one level up).
_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(_HERE))
sys.path.insert(0, _HERE)
import shadow_report as sr  # noqa: E402

T0 = 1790608898


def mem(ts, choice, shown, *, direction="out", store="kartya", rank=1, latency=300,
        tokens=800, outcome="provider_called", placeholders=None, conf=0.8):
    return {"ts": ts, "task": "memory", "policy": "d005-shadow-v1", "redaction_version": "r9",
            "local": {"score": 1, "store": store, "rank": rank, "shown": shown, "direction": direction},
            "input_hash": "abc", "placeholders": placeholders if placeholders is not None else {"DATE": 1},
            "outcome": outcome, "model": "jev-1.13.0",
            "answers": {"rel": {"choice": choice, "confidence": conf}},
            "latency_ms": latency, "input_tokens": tokens}


def out(ts, *, verdict="allow", kinds=(), defer="NO", multi="NO", latency=400, channel="Discord",
        outcome="provider_called"):
    return {"ts": ts, "task": "outgoing", "policy": "d005-shadow-v1", "redaction_version": "r9",
            "local": {"verdict": verdict, "kinds": list(kinds), "channel": channel},
            "input_hash": "abc", "placeholders": {"DATE": 1}, "outcome": outcome, "model": "jev-1.13.0",
            "answers": {"defer": {"choice": defer, "confidence": 0.2},
                        "reopen": {"choice": "NO", "confidence": 0.3},
                        "jargon": {"choice": "NO", "confidence": 0.1},
                        "multi": {"choice": multi, "confidence": 0.8}},
            "latency_ms": latency, "input_tokens": 700}


def local_time(ts):
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(ts))


class Store:
    def __init__(self, shadow=(), decisions=(), recall=(), extra_shadow_lines=()):
        self.dir = tempfile.mkdtemp()
        with open(os.path.join(self.dir, "jev-shadow.jsonl"), "w", encoding="utf-8") as f:
            for r in shadow:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")
            for line in extra_shadow_lines:
                f.write(line + "\n")
        with open(os.path.join(self.dir, "outgoing-copy-gate-decisions.jsonl"), "w", encoding="utf-8") as f:
            for r in decisions:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")
        with open(os.path.join(self.dir, "prior-art-recall.log"), "w", encoding="utf-8") as f:
            f.write("2026-09-02 09:50:28\tregi,harom,oszlop\t8\n")
            for ts, kw, hits, chars, direction, brake in recall:
                f.write(f"{local_time(ts)}\t{kw}\t{hits}\t{chars}\t{direction}\t{brake}\n")

    def run(self, *extra):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            code = sr.main(["--store", self.dir, *extra])
        return code, buf.getvalue()

    def report(self, **kw):
        s, _ = sr.shadow_rows(os.path.join(self.dir, "jev-shadow.jsonl"), 0)
        d, _ = sr.decision_rows(os.path.join(self.dir, "outgoing-copy-gate-decisions.jsonl"), 0)
        r, _, _ = sr.recall_rows(os.path.join(self.dir, "prior-art-recall.log"), 0)
        return sr.analyse(s, d, r, kw.get("cold_ms", 9000), kw.get("window", 10))


class Outcomes(unittest.TestCase):
    def test_distribution_and_blocked_share_ignore_disabled(self):
        rep = Store([mem(T0, "RELEVANT", True), mem(T0 + 1, "RELEVANT", True, outcome="blocked_runtime_guard"),
                     mem(T0 + 2, "RELEVANT", True, outcome="disabled"),
                     mem(T0 + 3, "RELEVANT", True, outcome="disabled"),
                     mem(T0 + 4, "RELEVANT", True, outcome="error_before_call")]).report()
        m = rep["by_task"]["memory"]
        self.assertEqual(m["outcomes"], {"disabled": 2, "blocked_runtime_guard": 1,
                                         "error_before_call": 1, "provider_called": 1})
        self.assertEqual(m["provider_called"], 1)
        self.assertEqual(m["blocked_share_of_active"], round(1 / 3, 4))
        self.assertEqual(m["errors"], 1)

    def test_unknown_outcome_is_other_not_echoed(self):
        rep = Store([mem(T0, "RELEVANT", True, outcome="valami_uj")]).report()
        self.assertEqual(rep["by_task"]["memory"]["outcomes"], {sr.OTHER: 1})


class Latency(unittest.TestCase):
    def test_cold_calls_are_separate_from_warm_percentiles(self):
        rows = [mem(T0 + i, "RELEVANT", True, latency=l)
                for i, l in enumerate([300, 310, 320, 330, 9500, 12000])]
        m = Store(rows).report()["by_task"]["memory"]
        self.assertEqual(m["cold_count"], 2)
        self.assertEqual([c["ms"] for c in m["cold_calls"]], [9500, 12000])
        self.assertEqual(m["latency_warm"]["max"], 330)
        self.assertEqual(m["latency_all"]["max"], 12000)
        self.assertEqual(m["latency_warm"]["p50"], 310)

    def test_threshold_is_inclusive_and_configurable(self):
        rows = [mem(T0, "RELEVANT", True, latency=9000), mem(T0 + 1, "RELEVANT", True, latency=6813)]
        self.assertEqual(Store(rows).report()["by_task"]["memory"]["cold_count"], 1)
        self.assertEqual(Store(rows).report(cold_ms=6000)["by_task"]["memory"]["cold_count"], 2)


class Placeholders(unittest.TestCase):
    def test_totals_per_call_and_empty_calls(self):
        rows = [mem(T0, "RELEVANT", True, placeholders={"PERSON": 2, "DATE": 1}),
                mem(T0 + 1, "RELEVANT", True, placeholders={}),
                mem(T0 + 2, "RELEVANT", True, placeholders={"PERSON": 1}, outcome="blocked_runtime_guard")]
        m = Store(rows).report()["by_task"]["memory"]
        self.assertEqual(m["placeholders_total"], {"PERSON": 2, "DATE": 1})
        self.assertEqual(m["placeholders_per_call"], 1.5)
        self.assertEqual(m["calls_without_placeholder"], 1)


class MemoryAgreement(unittest.TestCase):
    def test_table_and_rates(self):
        rows = [mem(T0, "RELEVANT", True), mem(T0 + 1, "NOT_RELEVANT", True),
                mem(T0 + 2, "RELEVANT", False), mem(T0 + 3, "NOT_RELEVANT", False),
                mem(T0 + 4, "NOT_RELEVANT", False), mem(T0 + 5, "UNCERTAIN", True, direction="in")]
        a = Store(rows).report()["by_task"]["memory"]["agreement"]
        self.assertIn({"jev": "RELEVANT", "local": "shown", "n": 1}, a["table"])
        self.assertIn({"jev": "NOT_RELEVANT", "local": "not_shown", "n": 2}, a["table"])
        self.assertEqual(a["shown"], {"n": 3, "relevant": 1})
        self.assertEqual(a["not_shown"], {"n": 3, "relevant": 1})
        self.assertEqual(a["by_direction"]["in"], {"n": 1, "relevant": 0})

    def test_rank_buckets(self):
        rows = [mem(T0, "RELEVANT", True, rank=1), mem(T0 + 1, "NOT_RELEVANT", True, rank=4),
                mem(T0 + 2, "NOT_RELEVANT", True, rank=8)]
        a = Store(rows).report()["by_task"]["memory"]["agreement"]
        self.assertEqual(a["by_rank"], {"1-2": {"n": 1, "relevant": 1}, "3-4": {"n": 1, "relevant": 0},
                                        "5-8": {"n": 1, "relevant": 0}})

    def test_brake_join_needs_same_direction_and_window(self):
        rows = [mem(T0, "RELEVANT", True), mem(T0 + 100, "NOT_RELEVANT", True),
                mem(T0 + 300, "RELEVANT", True)]
        recall = [(T0 + 2, "kw", 8, 1500, "out", 1),        # matches row 1 -> brake on
                  (T0 + 101, "kw", 8, 1500, "in", 1),       # wrong direction for row 2
                  (T0 + 105, "kw", 8, 1500, "out", 0),      # matches row 2 -> brake off
                  (T0 + 330, "kw", 8, 1500, "out", 1)]      # 30 s away from row 3 -> unmatched
        b = Store(rows, recall=recall).report()["by_task"]["memory"]["agreement"]["brake"]
        self.assertEqual((b["matched"], b["unmatched"]), (2, 1))
        self.assertEqual(b["brake_on"], {"n": 1, "relevant": 1})
        self.assertEqual(b["brake_off"], {"n": 1, "relevant": 0})


class OutgoingAgreement(unittest.TestCase):
    def test_questions_vs_verdict_and_defer_vs_rule(self):
        rows = [out(T0, verdict="allow", defer="NO"),
                out(T0 + 1, verdict="deny", kinds=["HALASZTAS"], defer="YES"),
                out(T0 + 2, verdict="would-deny", kinds=["HALASZTAS", "GONDOLATJEL"], defer="NO"),
                out(T0 + 3, verdict="allow", defer="YES", multi="YES")]
        a = Store(rows).report()["by_task"]["outgoing"]["agreement"]
        self.assertIn({"jev": "YES", "local": "stopped", "n": 1}, a["per_question_vs_verdict"]["defer"])
        self.assertIn({"jev": "NO", "local": "stopped", "n": 1}, a["per_question_vs_verdict"]["defer"])
        self.assertEqual(sorted((x["jev"], x["local"], x["n"]) for x in a["defer_vs_HALASZTAS"]),
                         [("NO", "HALASZTAS", 1), ("NO", "nincs", 1), ("YES", "HALASZTAS", 1), ("YES", "nincs", 1)])
        self.assertEqual(a["local_kinds"], {"HALASZTAS": 2, "GONDOLATJEL": 1})

    def test_coverage_counts_decisions_without_shadow_row(self):
        rows = [out(T0), out(T0 + 50, channel="Telegram")]
        decisions = [{"ts": T0, "channel": "Discord", "verdict": "allow", "kinds": [], "len": 10},
                     {"ts": T0 + 50, "channel": "Discord", "verdict": "allow", "kinds": [], "len": 10},
                     {"ts": T0 + 200, "channel": "Discord", "verdict": "deny", "kinds": ["HALASZTAS x"], "len": 10},
                     {"ts": T0 + 5, "channel": "email", "verdict": "allow", "kinds": [], "len": 10}]
        c = Store(rows, decisions=decisions).report()["by_task"]["outgoing"]["coverage"]
        self.assertEqual((c["chat_decisions"], c["with_shadow_row"], c["without_shadow_row"]), (3, 1, 2))


class CoverageIsOneToOne(unittest.TestCase):
    def test_one_shadow_row_cannot_answer_two_decisions(self):
        decisions = [{"ts": T0, "channel": "Discord", "verdict": "allow", "kinds": [], "len": 10},
                     {"ts": T0 + 2, "channel": "Discord", "verdict": "allow", "kinds": [], "len": 10}]
        c = Store([out(T0 + 1)], decisions=decisions).report()["by_task"]["outgoing"]["coverage"]
        self.assertEqual((c["with_shadow_row"], c["without_shadow_row"]), (1, 1))


class WhyACallWasSlow(unittest.TestCase):
    """Sleep, concurrency, or neither -- per call, across both tasks."""

    def rows(self, report):
        return report["timing"]

    def test_idle_is_measured_from_the_latest_earlier_end(self):
        t = Store([mem(T0, "RELEVANT", True, latency=300),
                   out(T0 + 100, latency=300),
                   mem(T0 + 200, "RELEVANT", True, latency=5000),
                   mem(T0 + 202, "RELEVANT", True, latency=300)]).report(cold_ms=4000)["timing"]
        self.assertEqual(t["calls"], 4)
        cold = t["cold_calls"]
        self.assertEqual(len(cold), 1)
        self.assertEqual(cold[0]["idle_s"], 99.7)          # 200 - (100 + 0.3)
        # the call at +202 started while the 5 s call was running: overlap, in flight 2
        self.assertEqual(t["by_in_flight"], {"1": {"n": 3, "cold": 1}, "2-3": {"n": 1, "cold": 0}})
        self.assertEqual(t["by_idle"]["elso hivas"], {"n": 1, "cold": 0})
        self.assertEqual(t["by_idle"]["<10 s"], {"n": 1, "cold": 0})   # the negative (overlap) idle

    def test_same_second_and_in_flight_in_a_burst(self):
        t = Store([mem(T0, "RELEVANT", True, latency=2000, rank=i) for i in range(1, 4)]).report()["timing"]
        self.assertEqual(t["by_same_second"], {"2-3": {"n": 3, "cold": 0}})
        self.assertEqual(t["by_in_flight"], {"1": {"n": 1, "cold": 0}, "2-3": {"n": 2, "cold": 0}})

    def test_bucket_edges(self):
        self.assertEqual(sr._bucket(3, sr.BURST_BUCKETS), "2-3")
        self.assertEqual(sr._bucket(8, sr.BURST_BUCKETS), "4-8")
        self.assertEqual(sr._bucket(9, sr.BURST_BUCKETS), "9+")
        self.assertEqual(sr._bucket(300, sr.IDLE_BUCKETS), "5-30 perc")
        self.assertEqual(sr._bucket(None, sr.IDLE_BUCKETS), "elso hivas")

    def test_the_two_by_two_grid_separates_sleep_from_concurrency(self):
        rows = [mem(T0, "RELEVANT", True, latency=12000)]                                 # first call: long idle, alone
        rows += [mem(T0 + 1000, "RELEVANT", True, latency=12000, rank=i) for i in range(1, 5)]  # long idle, burst
        rows += [out(T0 + 1100, latency=300)]                                              # short idle, alone
        rows += [mem(T0 + 1120, "RELEVANT", True, latency=300, rank=i) for i in range(1, 4)]    # short idle, burst
        g = Store(rows).report()["timing"]["grid"]
        self.assertEqual(g, {"hosszu_szunet_egyedul": {"n": 1, "cold": 1},
                             "hosszu_szunet_csomagban": {"n": 4, "cold": 4},
                             "rovid_szunet_egyedul": {"n": 1, "cold": 0},
                             "rovid_szunet_csomagban": {"n": 3, "cold": 0}})

    def test_an_ended_call_is_not_in_flight_and_an_overlap_is_a_burst(self):
        # A runs 10 s; B starts at +2 and ends at +2.3; C starts at +5: only A is still running.
        # C is alone in its second, yet overlaps A -> it belongs to the burst column.
        # C's latency sits exactly on the cold threshold, which counts as cold.
        t = Store([mem(T0, "RELEVANT", True, latency=10000),
                   mem(T0 + 2, "RELEVANT", True, latency=300),
                   mem(T0 + 5, "RELEVANT", True, latency=9000)]).report(cold_ms=9000)["timing"]
        c = [x for x in t["cold_calls"] if x["time"] == sr.iso(T0 + 5)]
        self.assertEqual(len(c), 1)
        self.assertEqual((c[0]["same_second"], c[0]["in_flight"]), (1, 2))
        self.assertEqual(t["grid"]["rovid_szunet_csomagban"], {"n": 2, "cold": 1})

    def test_only_provider_calls_count(self):
        t = Store([mem(T0, "RELEVANT", True), mem(T0, "RELEVANT", True, outcome="disabled"),
                   mem(T0, "RELEVANT", True, outcome="blocked_runtime_guard")]).report()["timing"]
        self.assertEqual(t["calls"], 1)
        self.assertEqual(t["by_same_second"], {"1": {"n": 1, "cold": 0}})


class NoTextEverLeaves(unittest.TestCase):
    """The hard rule. Text is planted in every field a careless hook could
    fill, and in the two neighbouring logs; none of it may reach the output."""

    SECRETS = ["Kovacs Bela titka", "bela@pelda.hu", "+36 30 123 4567", "cmufp2q4k0009mq07zx748r4z",
               "RELEVANT mert Balazs", "jev-latest-Balazs", "r9 Balazs", "HALASZTAS: holnap reggel",
               "kulcsszo-szoveg-ami-nem-mehet-ki", "sha-ertek-ami-nem-mehet-ki", "cwd-nev-titok"]

    def test_planted_text_is_absent_from_markdown_and_json(self):
        s = self.SECRETS
        evil = mem(T0, "RELEVANT", True)
        evil["local"].update({"store": s[0], "direction": s[1], "note": s[2]})
        evil["input_hash"] = s[3]
        evil["answers"] = {"rel": {"choice": s[4], "confidence": 0.9}, s[0]: {"choice": "YES"}}
        evil["model"] = s[5]
        evil["redaction_version"] = s[6]
        evil["policy"] = s[0]
        evil["placeholders"] = {s[1]: 3, "DATE": 1}
        evil["outcome"] = s[2]
        evil2 = out(T0 + 1, verdict=s[0], kinds=[s[7], "HALASZTAS"], channel=s[2])
        evil2["message"] = s[0]
        decisions = [{"ts": T0 + 1, "channel": s[1], "verdict": s[0], "kinds": [s[7]], "len": 5,
                      "sha256": s[9], "cwd": s[10]}]
        recall = [(T0 + 2, s[8], 8, 1500, "out", 1)]
        st = Store([evil, evil2, mem(T0 + 3, "RELEVANT", True)], decisions=decisions, recall=recall,
                   extra_shadow_lines=['{"nem": "zart', "Kovacs Bela szabad szovege"])
        code, md = st.run()
        self.assertEqual(code, 0)
        outdir = tempfile.mkdtemp()
        st.run("--out", outdir)
        with open(os.path.join(outdir, "shadow-report.json"), encoding="utf-8") as f:
            js = f.read()
        with open(os.path.join(outdir, "shadow-report.md"), encoding="utf-8") as f:
            md2 = f.read()
        for text in (md, md2, js):
            for secret in s:
                self.assertNotIn(secret, text)
            for fragment in ("Kovacs", "Balazs", "pelda.hu", "holnap", "123 4567"):
                self.assertNotIn(fragment, text)
        self.assertIn(sr.OTHER, md)          # the planted values were counted, as "other"
        self.assertIn("hibás sor: 2", md)    # the two broken lines were counted, not printed

    def test_versions_are_rebuilt_not_echoed(self):
        self.assertEqual(sr._versionish("jev-1.13.0", "jev-"), "jev-1.13.0")
        self.assertEqual(sr._versionish("r9", "r"), "r9")
        self.assertEqual(sr._versionish("r9x", "r"), sr.OTHER)
        self.assertEqual(sr._versionish("jev-latest", "jev-"), sr.OTHER)
        self.assertEqual(sr._versionish(None, "r"), sr.MISSING)


class Cli(unittest.TestCase):
    def test_missing_shadow_log_exits_2_without_traceback(self):
        d = tempfile.mkdtemp()
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            code = sr.main(["--store", d])
        self.assertEqual(code, 2)
        self.assertIn("nincs ilyen fájl", err.getvalue())

    def test_since_filters_rows(self):
        st = Store([mem(T0, "RELEVANT", True), mem(T0 + 100, "RELEVANT", True)])
        _, md = st.run("--since", str(T0 + 50))
        self.assertIn("sorok: 1,", md)

    def test_reads_only(self):
        st = Store([mem(T0, "RELEVANT", True)], recall=[(T0, "kw", 8, 1500, "out", 0)])
        before = {n: os.stat(os.path.join(st.dir, n)).st_mtime_ns for n in os.listdir(st.dir)}
        st.run()
        after = {n: os.stat(os.path.join(st.dir, n)).st_mtime_ns for n in os.listdir(st.dir)}
        self.assertEqual(before, after)


if __name__ == "__main__":
    unittest.main()
