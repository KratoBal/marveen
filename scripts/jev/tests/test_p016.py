"""P-016 prototype: one provider call per recall message. No network: the
provider is replaced, and every test says whether it was reached, with what,
and what ended up in the log."""
import json
import os
import sys
import tempfile
import unittest

_JEV = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, _JEV)

# The shadow module reads its paths at import time, and test_shadow.py sets its
# own. This file must not win that race when both run in one process, so it
# only fills the environment if nobody has, imports lazily, and points the
# module's paths at its own directory for the length of each test.
_TMP = tempfile.mkdtemp()
os.environ.setdefault("JEV_STORE", _TMP)
os.environ.setdefault("JEV_LEAK_GATE_STATUS", os.path.join(_TMP, "jev-leak-gate.json"))
os.environ.setdefault("JEV_KNOWN_ENTITIES", os.path.join(_TMP, "known.json"))
shadow = redact = leak_gate = None
_PATHS = {"STORE": "", "SWITCH": "jev-shadow.json", "GATE": "jev-leak-gate.json",
          "LOG": "jev-shadow.jsonl", "KEY_FILE": ".jev-api-key", "SALT_FILE": ".jev-hash-salt"}

QUERY = "Kovács Péter kérdezi, mi lett a szivattyúval?"
CANDS = ["a szivattyú kattog a Kovácséknál", "a lámpa kiégett", "szivattyú csere megrendelve"]


def cands(texts=CANDS):
    return [{"candidate": t, "local": {"score": 2, "store": "kartya", "rank": i, "shown": i < 2,
                                       "direction": "out"}} for i, t in enumerate(texts)]


def by_content(fields, questions):
    """A fake provider that answers from the CONTENT of each field: a
    candidate about the pump is RELEVANT. Keys come back in REVERSED order,
    so a position-based mapping would give the wrong row the wrong answer."""
    out = {}
    for key in reversed(sorted(questions)):
        field = "c" + key.split("_")[1]
        pump = "szivatty" in fields[field]
        if key.startswith("rel_"):
            out[key] = {"choice": "RELEVANT" if pump else "NOT_RELEVANT", "confidence": 0.9}
        else:
            out[key] = {"choice": "SAME_SUBJECT" if pump else "OTHER_SUBJECT", "confidence": 0.7}
    return out


class Batch(unittest.TestCase):
    def setUp(self):
        global shadow, redact, leak_gate
        import leak_gate as _lg
        import redact as _rd
        import shadow as _sh
        shadow, redact, leak_gate = _sh, _rd, _lg
        self._paths = {k: getattr(shadow, k) for k in _PATHS}
        for k, name in _PATHS.items():
            setattr(shadow, k, os.path.join(_TMP, name) if name else _TMP)
        self._shuffle, self._reason = shadow._shuffle, shadow.WITH_REASON
        self.calls = []
        self.answer = by_content

        def fake(dto, questions):
            self.calls.append((dto, questions))
            if not isinstance(dto, shadow.RedactedDTO):
                raise shadow.Blocked("blocked_not_redacted")
            return {"model": "jev-1.13.0", "answers": self.answer(dto.fields, questions),
                    "usage": {"input_tokens": 1234}}, 777
        self._orig = shadow._call_provider
        shadow._call_provider = fake
        for f in ("jev-shadow.json", "jev-leak-gate.json", "known.json", "jev-shadow.jsonl", ".jev-hash-salt"):
            try:
                os.remove(os.path.join(_TMP, f))
            except OSError:
                pass
        redact._KNOWN_CACHE.clear()

    def tearDown(self):
        shadow._call_provider = self._orig
        shadow._shuffle, shadow.WITH_REASON = self._shuffle, self._reason
        for k, v in self._paths.items():
            setattr(shadow, k, v)

    def on(self):
        with open(shadow.SWITCH, "w") as f:
            json.dump({"enabled": True}, f)
        with open(shadow.GATE, "w") as f:
            json.dump({"leaks": 0, "redaction_version": redact.REDACTION_VERSION,
                       "code_hash": leak_gate.code_hash()}, f)

    def run_batch(self, texts=CANDS, query=QUERY):
        return shadow.run_batch({"task": "memory_batch", "query": query, "candidates": cands(texts)})

    def log(self):
        with open(shadow.LOG, encoding="utf-8") as f:
            return [json.loads(line) for line in f]

    # ----------------------------------------------------------- the call
    def test_one_call_for_all_candidates_with_redacted_fields(self):
        self.on()
        rows = self.run_batch()
        self.assertEqual(len(self.calls), 1)
        dto, questions = self.calls[0]
        self.assertEqual(sorted(dto.fields), ["c0", "c1", "c2", "query"])
        self.assertEqual(sorted(questions), ["rel_0", "rel_1", "rel_2"])
        sent = json.dumps(dto.fields, ensure_ascii=False)
        self.assertNotIn("Kovács", sent)
        self.assertNotIn("Péter", sent)
        self.assertEqual([r["outcome"] for r in rows], ["provider_called"] * 3)
        self.assertEqual(len({r["call_id"] for r in rows}), 1)

    def test_log_shape_one_row_per_candidate_cost_on_first_only(self):
        self.on()
        self.run_batch()
        log = self.log()
        self.assertEqual(len(log), 3)
        self.assertTrue(all(r["task"] == "memory" and r["policy"] == "d005-shadow-v2" for r in log))
        self.assertEqual([r["batch_index"] for r in log], [0, 1, 2])
        self.assertEqual([r.get("latency_ms") for r in log], [777, None, None])
        self.assertEqual([r.get("input_tokens") for r in log], [1234, None, None])
        self.assertEqual([r["local"]["rank"] for r in log], [0, 1, 2])

    # ----------------------------------------------------------- answers
    def test_swapped_order_is_matched_by_key(self):
        self.on()
        rows = self.run_batch()
        self.assertEqual([r["answers"]["rel"]["choice"] for r in rows],
                         ["RELEVANT", "NOT_RELEVANT", "RELEVANT"])

    def assert_invalid(self, rows, detail):
        self.assertEqual({r["outcome"] for r in rows}, {"batch_invalid"})
        self.assertEqual({r["detail"] for r in rows}, {detail})
        self.assertTrue(all("answers" not in r for r in rows))
        self.assertEqual(rows[0]["latency_ms"], 777)      # the call happened: its cost stays

    def test_one_missing_answer_invalidates_the_whole_batch(self):
        self.on()
        self.answer = lambda f, q: {k: v for k, v in by_content(f, q).items() if k != "rel_1"}
        self.assert_invalid(self.run_batch(), "missing")

    def test_an_unrequested_key_invalidates_the_whole_batch(self):
        self.on()
        self.answer = lambda f, q: {**by_content(f, q), "rel_3": {"choice": "RELEVANT", "confidence": 1}}
        rows = self.run_batch()
        self.assert_invalid(rows, "extra")
        self.assertEqual(len(self.log()), 3)

    def test_an_invalid_choice_invalidates_the_whole_batch_without_echo(self):
        self.on()
        self.answer = lambda f, q: {**by_content(f, q), "rel_0": {"choice": "Kovács Péter", "confidence": 1}}
        self.assert_invalid(self.run_batch(), "shape")
        self.assertNotIn("Kovács", json.dumps(self.log(), ensure_ascii=False))

    def test_a_non_numeric_confidence_is_a_shape_error(self):
        self.on()
        self.answer = lambda f, q: {**by_content(f, q), "rel_2": {"choice": "RELEVANT", "confidence": "high"}}
        self.assert_invalid(self.run_batch(), "shape")

    def test_answers_not_a_dict(self):
        self.on()
        self.answer = lambda f, q: ["RELEVANT", "RELEVANT", "RELEVANT"]
        self.assert_invalid(self.run_batch(), "shape")

    def test_several_problems_are_named_in_a_fixed_order(self):
        self.on()
        self.answer = lambda f, q: {"rel_0": {"choice": "RELEVANT", "confidence": 1}, "zzz": {}}
        self.assert_invalid(self.run_batch(), "missing,extra")

    # ----------------------------------------------------------- outputs and keys
    def test_uncertain_is_a_valid_answer(self):
        self.on()
        self.run_batch()
        questions = self.calls[0][1]
        self.assertIn("UNCERTAIN", questions["rel_0"]["criteria"])
        self.answer = lambda f, q: {k: {"choice": "UNCERTAIN", "confidence": 0.4} for k in q}
        rows = self.run_batch()
        self.assertEqual({r["answers"]["rel"]["choice"] for r in rows}, {"UNCERTAIN"})

    def test_keys_do_not_follow_rank_order(self):
        self.on()
        shadow._shuffle = lambda xs: xs.reverse()          # deterministic stand-in for the random order
        rows = self.run_batch(["szivattyú első", "lámpa második", "lámpa harmadik"])
        dto, _ = self.calls[0]
        self.assertIn("harmadik", dto.fields["c0"])         # c0 is NOT the best-ranked candidate
        self.assertIn("első", dto.fields["c2"])
        self.assertEqual([r["answers"]["rel"]["choice"] for r in rows],
                         ["RELEVANT", "NOT_RELEVANT", "NOT_RELEVANT"])
        self.assertEqual([r["batch_index"] for r in rows], [0, 1, 2])

    def test_the_shuffle_is_really_applied(self):
        self.on()
        seen = []
        shadow._shuffle = lambda xs: seen.append(len(xs))
        self.run_batch()
        self.assertEqual(seen, [3])

    def test_optional_reason_code_from_a_closed_list(self):
        self.on()
        shadow.WITH_REASON = True
        rows = self.run_batch()
        _, questions = self.calls[0]
        self.assertEqual(sorted(questions), ["rel_0", "rel_1", "rel_2", "why_0", "why_1", "why_2"])
        self.assertEqual(sorted(questions["why_0"]["criteria"]), sorted(shadow.REASON_CODES))
        self.assertEqual([r["answers"]["reason"] for r in rows],
                         ["SAME_SUBJECT", "OTHER_SUBJECT", "SAME_SUBJECT"])

    def test_a_free_text_reason_invalidates_the_batch(self):
        self.on()
        shadow.WITH_REASON = True
        self.answer = lambda f, q: {**by_content(f, q),
                                    "why_1": {"choice": "mert Kovács Péter mondta", "confidence": 1}}
        self.assert_invalid(self.run_batch(), "shape")
        self.assertNotIn("Kovács", json.dumps(self.log(), ensure_ascii=False))

    def test_reason_off_by_default(self):
        self.on()
        rows = self.run_batch()
        self.assertTrue(all("reason" not in r["answers"] for r in rows))
        self.assertEqual(sorted(self.calls[0][1]), ["rel_0", "rel_1", "rel_2"])

    # ----------------------------------------------------------- per-candidate redaction
    def test_a_candidate_that_fails_redaction_is_left_out_of_the_call(self):
        self.on()
        orig = redact.redact

        def picky(text, **kw):
            if "lámpa" in text:
                raise redact.RedactionError("x")
            return orig(text, **kw)
        redact.redact = picky
        try:
            rows = self.run_batch()
        finally:
            redact.redact = orig
        self.assertEqual(rows[1]["outcome"], "blocked_redaction_error")
        self.assertNotIn("call_id", rows[1])
        dto, questions = self.calls[0]
        self.assertEqual(sorted(dto.fields), ["c0", "c1", "query"])      # two candidates went
        # rel_1 in the call is the THIRD candidate: the mapping follows the call, not the input
        self.assertEqual(rows[2]["answers"]["rel"]["choice"], "RELEVANT")
        self.assertEqual(rows[0]["answers"]["rel"]["choice"], "RELEVANT")

    def test_query_that_fails_redaction_blocks_every_row_and_the_call(self):
        self.on()
        orig = redact.redact

        def boom(text, **kw):
            if "kérdezi" in text:
                raise redact.RedactionError("x")
            return orig(text, **kw)
        redact.redact = boom
        try:
            rows = self.run_batch()
        finally:
            redact.redact = orig
        self.assertEqual([r["outcome"] for r in rows], ["blocked_redaction_error"] * 3)
        self.assertEqual(self.calls, [])

    def test_all_candidates_failing_means_no_call(self):
        self.on()
        orig = redact.redact

        def boom(text, **kw):
            if "kérdezi" not in text:
                raise redact.RedactionError("x")
            return orig(text, **kw)
        redact.redact = boom
        try:
            rows = self.run_batch()
        finally:
            redact.redact = orig
        self.assertEqual(self.calls, [])
        self.assertEqual({r["outcome"] for r in rows}, {"blocked_redaction_error"})

    # ----------------------------------------------------------- gates and limits
    def test_off_and_red_gate_never_call(self):
        rows = self.run_batch()
        self.assertEqual({r["outcome"] for r in rows}, {"disabled"})
        with open(shadow.SWITCH, "w") as f:
            json.dump({"enabled": True}, f)
        rows = self.run_batch()
        self.assertEqual({r["outcome"] for r in rows}, {"blocked_leak_gate"})
        self.assertEqual(self.calls, [])

    def test_combined_dto_refuses_anything_not_redacted(self):
        with self.assertRaises(shadow.Blocked):
            shadow._combined_dto({"query": "nyers"}, [])
        with self.assertRaises(shadow.Blocked):
            shadow._combined_dto(shadow.RedactedDTO({"query": "x"}, "r0", {}, ""), [])

    def test_batch_is_capped(self):
        self.on()
        rows = self.run_batch(["szivattyú %d" % i for i in range(15)])
        self.assertEqual(len(rows), shadow.MAX_BATCH)
        self.assertEqual(len(self.calls[0][1]), shadow.MAX_BATCH)

    def test_provider_error_keeps_rows_and_names_the_error(self):
        self.on()

        def fail(dto, questions):
            raise TimeoutError()
        shadow._call_provider = fail
        rows = self.run_batch()
        self.assertEqual({r["outcome"] for r in rows}, {"provider_called"})
        self.assertEqual({r["error"] for r in rows}, {"TimeoutError"})

    # ----------------------------------------------------------- no text, report
    def test_log_has_no_text(self):
        self.on()
        self.run_batch()
        with open(shadow.LOG, encoding="utf-8") as f:
            raw = f.read()
        for s in ("Kovács", "Péter", "szivattyú", "lámpa", "PERSON_1>"):
            self.assertNotIn(s, raw)
        # field names as JSON keys; a bare "c0" can occur inside a random hex id
        for key in ('"c0"', '"query"', '"candidate"'):
            self.assertNotIn(key, raw)

    def test_report_reads_the_batch_log_unchanged(self):
        import shadow_report
        self.on()
        self.run_batch()
        s, _ = shadow_report.shadow_rows(shadow.LOG, 0)
        rep = shadow_report.analyse(s, [], [], 9000, 10)
        self.assertNotIn("memory", rep["by_task"])          # v2 has its own section
        m = rep["by_task"]["memory_v2"]
        self.assertEqual(m["provider_called"], 3)
        self.assertEqual(m["calls"], 1)                     # three rows, one call
        self.assertEqual(m["tokens"]["sum"], 1234)          # not 3 x 1234
        self.assertEqual(rep["timing_v2"]["calls"], 1)      # one call, not a burst of three
        self.assertEqual(rep["timing"]["calls"], 0)         # nothing before v2 in this log
        self.assertEqual(m["policies"], {"d005-shadow-v2": 3})
        self.assertEqual(m["agreement"]["shown"], {"n": 2, "relevant": 1})


if __name__ == "__main__":
    unittest.main()


class ReportKeepsV1AndV2Apart(unittest.TestCase):
    """ACD-013 point 4 and point 1, on the report side."""

    def rows(self):
        base = {"task": "memory", "redaction_version": "r10", "model": "jev-1.13.0",
                "placeholders": {"DATE": 1}, "input_tokens": 500}
        v1 = [dict(base, ts=1000 + i, policy="d005-shadow-v1", outcome="provider_called", latency_ms=300,
                   local={"shown": True, "direction": "out", "store": "kartya", "rank": i},
                   answers={"rel": {"choice": "RELEVANT", "confidence": 0.9}}) for i in range(4)]
        v2 = [dict(base, ts=2000, policy="d005-shadow-v2", outcome="provider_called", call_id="aa",
                   batch_index=i, local={"shown": True, "direction": "out", "store": "kartya", "rank": i},
                   answers={"rel": {"choice": "NOT_RELEVANT", "confidence": 0.8}, "reason": "OTHER_SUBJECT"},
                   **({"latency_ms": 900} if i == 0 else {"input_tokens": None})) for i in range(3)]
        bad = [dict(base, ts=3000, policy="d005-shadow-v2", outcome="batch_invalid", detail="missing,extra",
                    call_id="bb", batch_index=i, local={"shown": True, "direction": "out"},
                    **({"latency_ms": 700} if i == 0 else {"input_tokens": None})) for i in range(2)]
        return v1 + v2 + bad

    def report(self):
        import shadow_report
        d = tempfile.mkdtemp()
        p = os.path.join(d, "jev-shadow.jsonl")
        with open(p, "w", encoding="utf-8") as f:
            for r in self.rows():
                f.write(json.dumps(r) + "\n")
        s, _ = shadow_report.shadow_rows(p, 0)
        return shadow_report.analyse(s, [], [], 9000, 10)

    def test_sections_and_periods_are_separate(self):
        rep = self.report()
        v1, v2 = rep["by_task"]["memory"], rep["by_task"]["memory_v2"]
        self.assertEqual((v1["provider_called"], v1["calls"]), (4, 4))
        self.assertEqual((v2["provider_called"], v2["calls"]), (3, 2))    # the invalid batch was a call too
        self.assertEqual((rep["timing"]["calls"], rep["timing_v2"]["calls"]), (4, 2))

    def test_invalid_batch_counts_as_cost_never_as_agreement(self):
        v2 = self.report()["by_task"]["memory_v2"]
        self.assertEqual(v2["batch_invalid"], 2)
        self.assertEqual(v2["batch_invalid_details"], {"extra": 2, "missing": 2})
        self.assertEqual(v2["agreement"]["shown"], {"n": 3, "relevant": 0})
        self.assertEqual(v2["latency_all"]["n"], 2)
        self.assertEqual(v2["agreement"]["reason_by_choice"],
                         [{"jev": "NOT_RELEVANT", "reason": "OTHER_SUBJECT", "n": 3}])
