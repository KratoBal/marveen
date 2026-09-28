"""Fail-closed properties of the D-005 provider boundary. No network: the
provider call is replaced, and every test asserts whether it was reached."""
import json
import os
import sys
import tempfile
import unittest

_JEV = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, _JEV)

_TMP = tempfile.mkdtemp()
os.environ["JEV_STORE"] = _TMP
os.environ["JEV_LEAK_GATE_STATUS"] = os.path.join(_TMP, "jev-leak-gate.json")
os.environ["JEV_KNOWN_ENTITIES"] = os.path.join(_TMP, "known.json")

import leak_gate  # noqa: E402
import redact  # noqa: E402
import shadow  # noqa: E402


class Boundary(unittest.TestCase):
    def setUp(self):
        self.calls = []

        def fake(dto, questions):
            self.calls.append(dto)
            if not isinstance(dto, shadow.RedactedDTO):
                raise shadow.Blocked("blocked_not_redacted")
            return {"model": "jev-1.13.0", "answers": {"rel": {"choice": "RELEVANT", "confidence": 0.9}},
                    "usage": {"input_tokens": 10}}, 5
        self._orig = shadow._call_provider
        shadow._call_provider = fake
        for f in ("jev-shadow.json", "jev-leak-gate.json", "known.json", "jev-shadow.jsonl"):
            try:
                os.remove(os.path.join(_TMP, f))
            except OSError:
                pass

    def tearDown(self):
        shadow._call_provider = self._orig

    def _switch(self, on):
        with open(shadow.SWITCH, "w") as f:
            json.dump({"enabled": on}, f)

    def _green(self, **over):
        g = {"leaks": 0, "redaction_version": redact.REDACTION_VERSION, "code_hash": leak_gate.code_hash()}
        g.update(over)
        with open(shadow.GATE, "w") as f:
            json.dump(g, f)

    def job(self, **kw):
        j = {"task": "memory", "query": "Kovács Péter mikor jön?", "candidate": "a szivattyú kattog"}
        j.update(kw)
        return shadow.run_job(j)

    def test_default_is_off(self):
        self._green()
        self.assertEqual(self.job()["outcome"], "disabled")
        self.assertEqual(self.calls, [])

    def test_switch_must_be_literal_true(self):
        self._green()
        self._switch("yes")
        self.assertEqual(self.job()["outcome"], "disabled")

    def test_missing_gate_blocks(self):
        self._switch(True)
        self.assertEqual(self.job()["outcome"], "blocked_leak_gate")
        self.assertEqual(self.calls, [])

    def test_gate_for_other_code_blocks(self):
        self._switch(True)
        self._green(code_hash="0" * 64)
        self.assertEqual(self.job()["outcome"], "blocked_leak_gate")
        self._green(redaction_version="r0")
        self.assertEqual(self.job()["outcome"], "blocked_leak_gate")
        self.assertEqual(self.calls, [])

    def test_green_path_sends_only_redacted(self):
        self._switch(True)
        self._green()
        row = self.job()
        self.assertEqual(row["outcome"], "provider_called")
        sent = self.calls[0].fields
        self.assertNotIn("Kovács", json.dumps(sent, ensure_ascii=False))
        self.assertIn("<PERSON_1>", sent["query"])

    def test_log_has_no_text(self):
        self._switch(True)
        self._green()
        self.job()
        log = open(shadow.LOG, encoding="utf-8").read()
        for s in ("Kovács", "Péter", "szivattyú", "PERSON_1>"):
            self.assertNotIn(s, log)

    def test_redaction_error_blocks(self):
        self._switch(True)
        self._green()
        orig = redact.redact

        def boom(text, **kw):
            raise redact.RedactionError("x")
        redact.redact = boom
        try:
            self.assertEqual(self.job()["outcome"], "blocked_redaction_error")
        finally:
            redact.redact = orig
        self.assertEqual(self.calls, [])

    def test_runtime_guard_blocks_known_entity(self):
        self._switch(True)
        self._green()
        # a known entity the property layer would miss: all lowercase, no shape
        orig = redact.redact

        def weak(text, **kw):
            return {"text": text, "version": redact.REDACTION_VERSION, "counts": {}}
        with open(os.environ["JEV_KNOWN_ENTITIES"], "w") as f:
            json.dump({"PERSON": ["zebulon kvarc"]}, f)
        redact.redact = weak
        try:
            row = self.job(query="szólj zebulon kvarcnak? zebulon kvarc", candidate="x")
        finally:
            redact.redact = orig
        self.assertEqual(row["outcome"], "blocked_runtime_guard")
        self.assertEqual(self.calls, [])

    def test_runtime_guard_blocks_secret(self):
        weak = {"text": ("token gh@@p_16C7e42F292c6912E7710c838347Ae178B4a").replace("@@", ""), "version": redact.REDACTION_VERSION}
        self.assertIn("SECRET", redact.runtime_guard(weak))
        self.assertEqual(redact.runtime_guard({"text": "x", "version": "r0"}), ["version"])

    def test_provider_refuses_plain_dict(self):
        with self.assertRaises(shadow.Blocked):
            self._orig({"query": "raw"}, {})

    def test_known_entity_layer_masks_lowercase(self):
        with open(os.environ["JEV_KNOWN_ENTITIES"], "w") as f:
            json.dump({"PERSON": ["zebulon kvarc"], "ORG": ["Tükörhal Bt"]}, f)
        out = redact.redact("szólj zebulon kvarcnak, a tukorhal bt fizetett")["text"]
        self.assertNotIn("zebulon", out)
        self.assertNotIn("tukorhal", out.lower())

    def test_corrupt_known_file_fails_closed(self):
        with open(os.environ["JEV_KNOWN_ENTITIES"], "w") as f:
            f.write("{not json")
        with self.assertRaises(redact.RedactionError):
            redact.redact("x")


if __name__ == "__main__":
    unittest.main()
