"""P-017 retrievability: every shadow row must say WHERE its query and its
candidate live (ids and keyed hashes), and never WHAT they say. The recall
hook side is tested in test_recall_refs.py."""
import json
import os
import sys
import tempfile
import unittest

_JEV = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, _JEV)

_TMP = tempfile.mkdtemp()
os.environ.setdefault("JEV_STORE", _TMP)
os.environ.setdefault("JEV_LEAK_GATE_STATUS", os.path.join(_TMP, "jev-leak-gate.json"))
os.environ.setdefault("JEV_KNOWN_ENTITIES", os.path.join(_TMP, "known.json"))
shadow = redact = leak_gate = None
_PATHS = {"STORE": "", "SWITCH": "jev-shadow.json", "GATE": "jev-leak-gate.json",
          "LOG": "jev-shadow.jsonl", "KEY_FILE": ".jev-api-key", "SALT_FILE": ".jev-hash-salt"}

QUERY = "Kovács Péter kérdezi, mi lett a szivattyúval?"


class Refs(unittest.TestCase):
    def setUp(self):
        global shadow, redact, leak_gate
        import leak_gate as _lg
        import redact as _rd
        import shadow as _sh
        shadow, redact, leak_gate = _sh, _rd, _lg
        self.dir = tempfile.mkdtemp()
        self._paths = {k: getattr(shadow, k) for k in _PATHS}
        for k, name in _PATHS.items():
            setattr(shadow, k, os.path.join(self.dir, name) if name else self.dir)
        self._orig = shadow._call_provider

        def fake(dto, questions):
            return {"model": "jev-1.13.0", "usage": {"input_tokens": 9},
                    "answers": {k: {"choice": "NOT_RELEVANT", "confidence": 0.5} for k in questions}}, 100
        shadow._call_provider = fake
        redact._KNOWN_CACHE.clear()

    def tearDown(self):
        shadow._call_provider = self._orig
        for k, v in self._paths.items():
            setattr(shadow, k, v)

    def on(self):
        with open(shadow.SWITCH, "w") as f:
            json.dump({"enabled": True}, f)
        with open(shadow.GATE, "w") as f:
            json.dump({"leaks": 0, "redaction_version": redact.REDACTION_VERSION,
                       "code_hash": leak_gate.code_hash()}, f)

    def batch(self, local=None, query_exact=None):
        job = {"task": "memory_batch", "query": QUERY,
               "candidates": [{"candidate": "a szivattyú kattog", "local": local or {"rank": 0}},
                              {"candidate": "a lámpa kiégett", "local": {"rank": 1}}]}
        if query_exact is not None:
            job["query_exact"] = query_exact
        return shadow.run_batch(job)

    def log(self):
        with open(shadow.LOG, encoding="utf-8") as f:
            return f.read()

    def test_rows_carry_keyed_hashes_of_query_and_candidate(self):
        self.on()
        rows = self.batch()
        self.assertEqual({r["query_hash"] for r in rows}, {shadow.text_hash(QUERY)})
        self.assertEqual([r["cand_hash"] for r in rows],
                         [shadow.text_hash("a szivattyú kattog"), shadow.text_hash("a lámpa kiégett")])
        self.assertNotEqual(rows[0]["cand_hash"], rows[1]["cand_hash"])

    def test_query_hash_is_over_the_exact_ledger_text(self):
        self.on()
        exact = "  " + QUERY + "\n"          # the reply tool's text, as the ledger stores it
        rows = self.batch(query_exact=exact)
        self.assertEqual(rows[0]["query_hash"], shadow.text_hash(exact))
        self.assertNotEqual(rows[0]["query_hash"], shadow.text_hash(QUERY))

    def test_hash_is_keyed(self):
        self.on()
        import hashlib
        rows = self.batch()
        plain = hashlib.blake2b(QUERY.encode(), digest_size=8).hexdigest()
        self.assertNotEqual(rows[0]["query_hash"], plain)

    def test_refs_in_local_survive_and_text_does_not(self):
        self.on()
        local = {"score": 2, "store": "komment", "rank": 0, "shown": True, "direction": "in",
                 "ref": "c1a2b3c4-0000-4000-8000-000000000001", "ref_card": "0b7e0c1e-7c1e-4c1e-9c1e-0c1e0c1e0c1e",
                 "q_kind": "channel", "q_chat": "1538522302277353505", "q_msg": "1554108767648489543",
                 "q_count": "2", "note": "Kovács Péter szövege"}   # 11 real keys + 1 text: the largest case
        rows = self.batch(local=local)
        got = rows[0]["local"]
        for k in ("ref", "ref_card", "q_kind", "q_chat", "q_msg", "q_count", "score", "store", "rank",
                  "shown", "direction"):
            self.assertEqual(got[k], local[k])
        self.assertNotIn("note", got)
        raw = self.log()
        for s in ("Kovács", "Péter", "szivattyú", "lámpa"):
            self.assertNotIn(s, raw)

    def test_disabled_writes_no_hash_and_creates_no_salt(self):
        rows = self.batch()
        self.assertEqual({r["outcome"] for r in rows}, {"disabled"})
        self.assertTrue(all("query_hash" not in r for r in rows))
        self.assertFalse(os.path.exists(shadow.SALT_FILE))

    def test_submit_batch_passes_query_exact(self):
        sent = []
        orig = shadow.submit
        shadow.submit = sent.append
        try:
            shadow.submit_batch("q", [], query_exact=" q ")
            shadow.submit_batch("q", [])
        finally:
            shadow.submit = orig
        self.assertEqual(sent[0]["query_exact"], " q ")
        self.assertNotIn("query_exact", sent[1])


if __name__ == "__main__":
    unittest.main()
