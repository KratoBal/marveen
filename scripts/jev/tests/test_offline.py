"""The offline measurement (offline.py). No network: the provider is replaced,
and every test says whether it was reached, with what, and what ended up in
the log. What must fail: text in the log, a call without --call, a call with
the leak gate red, a call with an unredacted piece, the holdout run twice,
or a log row that cannot be joined to its label."""
import json
import os
import sys
import tempfile
import unittest

_JEV = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, _JEV)

# Same arrangement as test_p016.py: fill the environment only if nobody has,
# import lazily, and point the module paths at this file's own directory.
_TMP = tempfile.mkdtemp()
os.environ.setdefault("JEV_STORE", _TMP)
os.environ.setdefault("JEV_LEAK_GATE_STATUS", os.path.join(_TMP, "jev-leak-gate.json"))
os.environ.setdefault("JEV_KNOWN_ENTITIES", os.path.join(_TMP, "known.json"))
shadow = redact = leak_gate = offline = None
_PATHS = {"STORE": "", "SWITCH": "jev-shadow.json", "GATE": "jev-leak-gate.json",
          "LOG": "jev-shadow.jsonl", "KEY_FILE": ".jev-api-key", "SALT_FILE": ".jev-hash-salt"}

PAYMENT = {"id": "a1b2c3d4e5f60718", "date": "2026-08-17", "amount": "1999", "currency": "HUF",
           "original": "", "partner": "Kovács Péter", "narrative": "SZ-2026/0815 Kovács Péter",
           "type": "ÁTUTALÁS",
           "candidates": [
               {"number": "SZ-2026/0815", "date": "2026-08-01", "gross": "1999", "currency": "HUF",
                "supplier": "Kovács Péter ev.", "source": "NAV"},
               {"number": "SZ-2026/0790", "date": "2026-07-01", "gross": "2499", "currency": "HUF",
                "supplier": "Kovács Péter ev.", "source": "NAV"}]}
LETTER = {"id": "f00dfeedcafe0001", "subject": "Számla Kovács Péter részére",
          "head": "SZÁMLA Eladó: Szállító Kft. Vevő: Acropora Kft. kovacs.peter@example.com"}
HALMAZ = {"A": [PAYMENT, dict(PAYMENT, id="ffff000011112222")], "B": [dict(PAYMENT, id="b0b0b0b0b0b0b0b0")]}
SPLIT = {"tetelek": {"a1b2c3d4e5f60718": "DEV", "ffff000011112222": "HOLDOUT", "b0b0b0b0b0b0b0b0": "DEV"}}


class Offline(unittest.TestCase):
    def setUp(self):
        global shadow, redact, leak_gate, offline
        import leak_gate as _lg
        import offline as _of
        import redact as _rd
        import shadow as _sh
        shadow, redact, leak_gate, offline = _sh, _rd, _lg, _of
        self._paths = {k: getattr(shadow, k) for k in _PATHS}
        for k, name in _PATHS.items():
            setattr(shadow, k, os.path.join(_TMP, name) if name else _TMP)
        self.calls = []
        self.reply = lambda questions: {k: {"choice": next(iter(q["criteria"])), "confidence": 0.93,
                                            "probabilities": {o: 0.1 for o in q["criteria"]}}
                                        for k, q in questions.items()}

        def fake(dto, questions):
            self.calls.append((dto, questions))
            if not isinstance(dto, shadow.RedactedDTO):
                raise shadow.Blocked("blocked_not_redacted")
            return {"model": "jev-1.13.0", "answers": self.reply(questions),
                    "usage": {"input_tokens": 321}}, 444
        self._orig = shadow._call_provider
        shadow._call_provider = fake
        for f in ("jev-shadow.json", "jev-leak-gate.json", "known.json", "jev-offline.jsonl", ".jev-hash-salt"):
            try:
                os.remove(os.path.join(_TMP, f))
            except OSError:
                pass
        redact._KNOWN_CACHE.clear()

    def tearDown(self):
        shadow._call_provider = self._orig
        for k, v in self._paths.items():
            setattr(shadow, k, v)

    def gate(self):
        with open(shadow.GATE, "w") as f:
            json.dump({"leaks": 0, "redaction_version": redact.REDACTION_VERSION,
                       "code_hash": leak_gate.code_hash()}, f)

    def log(self):
        try:
            with open(os.path.join(_TMP, "jev-offline.jsonl"), encoding="utf-8") as f:
                return [json.loads(line) for line in f]
        except FileNotFoundError:
            return []

    # ----------------------------------------------------------- the boundary
    def test_the_pairing_keeps_business_data_and_masks_personal_data(self):
        """Balázs, 2026-10-01 04:38 UTC: the pairing may see the amount, the date,
        the invoice number and the company; never a person, an e-mail, a phone,
        a bank account or a tax number, and a private partner's name stays out."""
        self.gate()
        item = dict(PAYMENT, partner="Tóth János",
                    narrative="ACRW-2026/00362 tel +36 20 123 4567 toth.janos@example.com "
                              "számla 11709002-20624460-00000000 adószám 12345678-2-42",
                    candidates=[{"number": "SZ-2026/0815", "date": "2026-08-01", "gross": "1999",
                                 "currency": "HUF", "supplier": "Szállító Kft.", "source": "NAV"},
                                {"number": "SZ-2026/0790", "date": "2026-07-01", "gross": "2499",
                                 "currency": "HUF", "supplier": "Nagy Anna ev.", "source": "NAV"}])
        row = offline.run_item("missing_invoice_pair", item, "DEV", call=True)
        self.assertEqual(row["outcome"], "provider_called")
        sent = json.dumps(self.calls[0][0].fields, ensure_ascii=False)
        for business in ("1999", "2026-08-17", "SZ-2026/0815", "ACRW-2026/00362", "Szállító Kft."):
            self.assertIn(business, sent, business)
        for personal in ("Tóth", "János", "Nagy", "Anna", "123 4567", "toth.janos",
                         "11709002-20624460", "12345678-2-42"):
            self.assertNotIn(personal, sent, personal)

    def test_a_private_partner_is_masked_before_redaction(self):
        self.assertEqual(offline._masked("Partner: Radván Norbert.", "Radván Norbert"),
                         "Partner: <PRIVATE_PARTNER>.")
        self.assertEqual(offline._masked("issuer: Kovács ev.", "Kovács ev."), "issuer: <PRIVATE_PARTNER>")
        for company in ("Szállító Kft.", "SIMPLEP*PARKL.NET", "Anthropic, PBC", "De Jong Marinelife B.V."):
            self.assertEqual(offline._masked(f"issuer: {company}", company), f"issuer: {company}", company)

    def test_the_pairing_keeps_company_names_whole_but_not_a_sole_trader(self):
        """acrobot 25498: every issuer came back as "<PERSON_1> Kft.", so the
        candidates could not be told apart. A name inside a company name with a
        real legal form stays; a sole trader's (ev.) does not."""
        self.gate()
        item = dict(PAYMENT, partner="SIMPLEP*PARKL.NET", narrative="E-PAR-2026-36143",
                    candidates=[{"number": "E-PAR-2026-36143", "date": "2026-08-01", "gross": "21699",
                                 "currency": "HUF", "supplier": "Parkl Digital Technologies Kft.",
                                 "source": "NAV"},
                                {"number": "SZ-2026/0790", "date": "2026-07-01", "gross": "2499",
                                 "currency": "HUF", "supplier": "Kovács Péter Kft.", "source": "NAV"},
                                {"number": "SZ-2026/0791", "date": "2026-07-02", "gross": "2500",
                                 "currency": "HUF", "supplier": "Szabó Géza ev.", "source": "NAV"}])
        offline.run_item("missing_invoice_pair", item, "DEV", call=True)
        fields = self.calls[0][0].fields
        self.assertIn("Parkl Digital Technologies Kft.", fields["c0"])
        self.assertIn("Kovács Péter Kft.", fields["c1"])
        self.assertNotIn("Szabó", fields["c2"])
        self.assertNotIn("Géza", fields["c2"])
        # the field labels are not masked into <PROPER_n> noise (the merchant
        # descriptor itself still is: PROPER and DOMAIN stay masked on purpose)
        for label in ("partner:", "reference:", "type:"):
            self.assertIn(label, fields["query"], label)

    def test_the_company_rule_is_the_pairing_modes_only(self):
        kept = redact.redact("issuer: Kovács Péter Kft.", keep_kinds=redact.PAIRING_KEEP)["text"]
        default = redact.redact("issuer: Kovács Péter Kft.")["text"]
        self.assertIn("Kovács Péter Kft.", kept)
        self.assertNotIn("Péter", default)
        # the sole trader stays masked in the pairing mode too, also without the
        # runner's own private-partner mask in front of the redactor
        for sole in ("issuer: Szabó Géza ev.", "issuer: Szabó Géza e.v."):
            self.assertNotIn("Géza", redact.redact(sole, keep_kinds=redact.PAIRING_KEEP)["text"], sole)

    def test_a_personal_kind_cannot_be_kept_by_anyone(self):
        with self.assertRaises(redact.RedactionError):
            redact.redact("Kovács Péter", keep_kinds={"PERSON"})
        self.assertTrue(redact.PAIRING_KEEP <= redact.KEEPABLE)
        self.assertFalse(redact.KEEPABLE & {"PERSON", "EMAIL", "PHONE", "ADDRESS", "IBAN",
                                            "BANK_ACCOUNT", "TAX_ID", "SECRET"})

    def test_the_other_tasks_redact_as_before(self):
        self.gate()
        offline.run_item("missing_invoice_category", PAYMENT, "DEV", call=True)
        sent = json.dumps(self.calls[0][0].fields, ensure_ascii=False)
        self.assertNotIn("SZ-2026/0815", sent)
        self.assertNotIn("1999 HUF", sent)

    def test_a_call_sends_only_redacted_pieces_and_logs_no_text(self):
        self.gate()
        row = offline.run_item("missing_invoice_pair", PAYMENT, "DEV", call=True)
        self.assertEqual(row["outcome"], "provider_called")
        dto, questions = self.calls[0]
        self.assertEqual(sorted(dto.fields), ["c0", "c1", "query"])
        sent = json.dumps(dto.fields, ensure_ascii=False)
        self.assertNotIn("Kovács", sent)
        self.assertNotIn("Péter", sent)
        line = json.dumps(self.log(), ensure_ascii=False)
        for raw in ("Kovács", "Péter", "SZ-2026/0815", "1999", "Számla", "Bank payment"):
            self.assertNotIn(raw, line, raw)

    def test_the_log_row_joins_its_label_and_holds_the_answer(self):
        self.gate()
        offline.run_item("missing_invoice_pair", PAYMENT, "DEV", call=True)
        (row,) = self.log()
        self.assertEqual((row["item"], row["side"], row["task"], row["choice"], row["confidence"]),
                         ("a1b2c3d4e5f60718", "DEV", "missing_invoice_pair", "c0", 0.93))
        self.assertEqual(sorted(row["probabilities"]), ["NONE", "c0", "c1"])
        self.assertEqual((row["latency_ms"], row["input_tokens"]), (444, 321))

    def test_a_letter_is_redacted_too(self):
        self.gate()
        offline.run_item("letter_class", LETTER, "DEV", call=True)
        dto, questions = self.calls[0]
        sent = json.dumps(dto.fields, ensure_ascii=False)
        self.assertNotIn("kovacs.peter@example.com", sent)
        self.assertNotIn("Kovács", sent)
        self.assertEqual(sorted(questions["kind"]["criteria"]), sorted(offline.LETTER_CLASSES))

    def test_an_answer_outside_the_options_is_not_a_measurement(self):
        self.gate()
        self.reply = lambda questions: {k: {"choice": "MADE_UP", "confidence": 1.0} for k in questions}
        row = offline.run_item("missing_invoice_category", PAYMENT, "DEV", call=True)
        self.assertNotIn("choice", row)
        self.assertIn("answer_not_an_option", row["error"])

    # ----------------------------------------------------------- the switches
    def test_the_default_is_a_dry_run_without_a_call_or_a_log(self):
        shown = []
        row = offline.run_item("missing_invoice_pair", PAYMENT, "DEV", call=False,
                               show=lambda item, fields: shown.append(fields))
        self.assertEqual((row["outcome"], self.calls, self.log()), ("dry_run", [], []))
        self.assertNotIn("Kovács", json.dumps(shown, ensure_ascii=False))

    def test_a_red_leak_gate_blocks_the_call(self):
        # a kategória-feladaton, ahol csak a kapu állíthatja meg a hívást
        row = offline.run_item("missing_invoice_category", PAYMENT, "DEV", call=True)
        self.assertEqual((row["outcome"], self.calls), ("blocked_leak_gate", []))

    def test_a_failed_redaction_blocks_the_call(self):
        self.gate()
        # a redact modul SAJÁT útja (egy másik tesztmodul is beállíthatta előbb),
        # de CSAK ideiglenes helyen: a valódi store-beli fájlhoz teszt nem nyúl
        path = redact.KNOWN_ENTITIES_PATH
        if not os.path.realpath(path).startswith(os.path.realpath(tempfile.gettempdir())):
            self.skipTest("the known-entity path is not a temporary file")
        with open(path, "w") as f:
            f.write("{ not json")
        redact._KNOWN_CACHE.clear()
        try:
            row = offline.run_item("missing_invoice_pair", PAYMENT, "DEV", call=True)
        finally:
            os.remove(path)
            redact._KNOWN_CACHE.clear()
        self.assertTrue(row["outcome"].startswith("blocked"), row["outcome"])
        self.assertEqual(self.calls, [])

    # ------------------------------------------------ known entities (25519)
    def known(self, entries):
        """The known-entity file, ONLY at a temporary path: the real store file
        is never touched by a test."""
        path = redact.KNOWN_ENTITIES_PATH
        if not os.path.realpath(path).startswith(os.path.realpath(tempfile.gettempdir())):
            self.skipTest("the known-entity path is not a temporary file")
        redact.write_known_file(entries, path)
        redact._KNOWN_CACHE.clear()
        self.addCleanup(redact._KNOWN_CACHE.clear)
        self.addCleanup(os.remove, path)

    def guard(self, text, allow=()):
        return redact.runtime_guard({"text": text, "version": redact.REDACTION_VERSION},
                                    allow_known_kinds=allow)

    def test_a_known_company_reaches_the_pairing_and_nothing_else(self):
        """acrobot 25519: the list's ORG entries are customer company names, the
        same data the pairing already shows as an issuer. Only the pairing lets
        them through; every other task still stops on them."""
        self.gate()
        self.known([("ORG", "Tisza 97 Kft."), ("PERSON", "Varga Ilona")])
        item = dict(PAYMENT, partner="SIMPLEP*FOXPOST", narrative="SZ-2026/0815",
                    candidates=[dict(PAYMENT["candidates"][0], supplier="Tisza 97 Kft."),
                                dict(PAYMENT["candidates"][1], supplier="Fluidra Kft.")])
        row = offline.run_item("missing_invoice_pair", item, "DEV", call=True)
        self.assertEqual(row["outcome"], "provider_called")
        self.assertIn("Tisza 97 Kft.", json.dumps(self.calls[0][0].fields, ensure_ascii=False))
        self.assertEqual(self.guard("issuer: Tisza 97 Kft.", redact.PAIRING_KNOWN_ALLOW), [])
        self.assertEqual(self.guard("issuer: Tisza 97 Kft."), ["KNOWN_ENTITY"])
        # the category task keeps no ORG: the name is masked before the guard
        # would see it, and if it ever came through, the guard stops it there
        self.calls.clear()
        offline.run_item("missing_invoice_category", item, "DEV", call=True)
        self.assertEqual(len(self.calls), 1)
        self.assertNotIn("Tisza", json.dumps(self.calls[0][0].fields, ensure_ascii=False))

    def test_a_known_person_or_sole_trader_still_stops_the_pairing(self):
        self.known([("PERSON", "Varga Ilona"), ("ORG", "Fekete Bolt")])
        allow = redact.PAIRING_KNOWN_ALLOW
        self.assertEqual(self.guard("issuer: Varga Ilona", allow), ["KNOWN_ENTITY"])
        # an ORG hit that is a sole trader's name, whatever the spelling
        for form in ("e.v.", "ev.", "E.V.", "e. v.", "egyéni vállalkozó"):
            self.assertEqual(self.guard(f"issuer: Fekete Bolt {form}, 5000 HUF", allow),
                             ["KNOWN_ENTITY"], form)
        self.assertEqual(self.guard("issuer: Fekete Bolt, 5000 HUF", allow), [])

    def test_only_org_can_be_allowed_past_the_known_entity_guard(self):
        self.known([("PERSON", "Varga Ilona")])
        self.assertEqual(self.guard("issuer: Varga Ilona", {"PERSON"}), ["allow_known_kinds"])
        self.assertEqual(self.guard("nothing known here", {"ORG", "EMAIL"}), ["allow_known_kinds"])

    def test_a_number_in_a_company_name_stays_in_the_name(self):
        """acrobot 25517: "Tisza 97 Kft." came out as "<PROPER_1> 97 Kft.". The
        number may be the last word before the legal form, nowhere else: an
        amount before a company name must not join it."""
        keep = redact.PAIRING_KEEP
        for name in ("Tisza 97 Kft.", "B-O 2001 Kft."):
            self.assertEqual(redact.redact(f"issuer: {name}", keep_kinds=keep)["text"],
                             f"issuer: {name}", name)
        out = redact.redact("Kovács János 45000 FoxPost Kft. díj", keep_kinds=keep)["text"]
        self.assertNotIn("Kovács", out)
        self.assertIn("FoxPost Kft.", out)

    def test_the_hook_switch_is_not_turned_on_by_a_measurement(self):
        self.gate()
        offline.run_item("missing_invoice_pair", PAYMENT, "DEV", call=True)
        self.assertFalse(os.path.exists(shadow.SWITCH))

    # ----------------------------------------------------------- the sides
    def write_inputs(self):
        h, s = os.path.join(_TMP, "h.json"), os.path.join(_TMP, "s.json")
        with open(h, "w") as f:
            json.dump(HALMAZ, f)
        with open(s, "w") as f:
            json.dump(SPLIT, f)
        return ["--halmaz", h, "--felosztas", s]

    def test_only_the_asked_side_runs(self):
        self.gate()
        offline.main(["--task", "missing_invoice_pair", "--call"] + self.write_inputs())
        self.assertEqual([r["item"] for r in self.log()], ["a1b2c3d4e5f60718"])

    def test_the_holdout_needs_its_own_flag_and_runs_once(self):
        self.gate()
        args = ["--task", "missing_invoice_pair", "--side", "HOLDOUT", "--call"] + self.write_inputs()
        with self.assertRaises(SystemExit):
            offline.main(args)
        self.assertEqual(self.calls, [])
        offline.main(args + ["--holdout-once"])
        self.assertEqual([r["item"] for r in self.log()], ["ffff000011112222"])
        with self.assertRaises(SystemExit):
            offline.main(args + ["--holdout-once"])
        self.assertEqual(len(self.calls), 1)

    def test_the_offline_file_is_part_of_the_gate(self):
        self.assertIn("offline.py", leak_gate.CODE_FILES)


if __name__ == "__main__":
    unittest.main()
