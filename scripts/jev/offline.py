#!/usr/bin/env python3
# ANSWERS: Mit mond a Jev a Hiányzó számlák párosításáról, a terhelés besorolásáról és a beérkező levél fajtájáról a címkézett halmazon (offline mérés, a flotta működésén semmit nem változtat)?
"""Offline Jev measurement for the two acropora-os plans (nautilus, 2026-10-01):
agents/nautilus/megosztas/jev-hianyzo-szamlak-terv-2026-10-01.md and
agents/nautilus/megosztas/jev-level-szetvalogatas-terv-2026-10-01.md.

A SEPARATE ENTRY POINT. The hook path (shadow.run_job, run_batch) is not
touched and does not call this file. What this file shares with it is the
guarded boundary: every text goes through shadow._redacted_dto() (redact()
and the runtime guard), a request is assembled only by shadow._combined_dto()
from RedactedDTOs, and only shadow._call_provider() reaches the network.
There is no other path to the provider here.

Preconditions for a provider call, all of them:
  1. --call on the command line (the default is a dry run: redact, show, no call);
  2. the leak gate is green for the code running now (shadow._gate_green()).
     This file is part of the gate's code hash, so editing it closes the gate
     until leak_gate.py passes again;
  3. redact() and the runtime guard succeeded for every piece.
The hook kill switch (store/jev-shadow.json) is NOT consulted: it governs the
hooks, and an explicit command-line run is its own switch. Turning hooks on
to measure would change the fleet's behaviour, which this file must not do.

THE HOLDOUT SIDE RUNS ONCE. --side HOLDOUT needs --holdout-once, and is
refused if the log already holds a called HOLDOUT row for the same task and
policy: the plans fix the holdout until tuning is over, then one run.

Log: store/jev-offline.jsonl, one row per item. Fields: ts, task, policy,
side, item (the dataset's own id, so a row joins its label), input_hash,
redaction_version, placeholders, outcome, model, choice, confidence,
probabilities (option keys only), latency_ms, input_tokens, error. Never text.

Usage:
  offline.py --task missing_invoice_pair --halmaz <halmaz.json> --felosztas <felosztas.json> [--side DEV] [--limit N] [--call]
  tasks: missing_invoice_pair (set A), missing_invoice_category (set B), letter_class
"""
import argparse
import json
import re
import os
import sys
import time
import urllib.error

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
import redact  # noqa: E402
import shadow  # noqa: E402

LOG_NAME = "jev-offline.jsonl"
MAX_QUERY_CHARS = 1500
MAX_CANDIDATE_CHARS = 400
MAX_LETTER_CHARS = 1500

POLICIES = {
    "missing_invoice_pair": "acropora-missing-invoice-pair-v1",
    "missing_invoice_category": "acropora-missing-invoice-category-v1",
    "letter_class": "acropora-letter-class-v1",
}

# The categories of acropora-os bank-transaction.classify.ts, plus the two
# barracuda proposed and nautilus accepted (acrobot 25454/25461). The text is
# the rule the product itself would apply, so Jev decides on the same terms.
CATEGORIES = {
    "DOMESTIC_SUPPLIER": "A payment to a Hungarian supplier for goods or services; an invoice is needed.",
    "FOREIGN_SUPPLIER": "A payment to a supplier abroad; an invoice is needed.",
    "CARD_SUBSCRIPTION": "A card payment for a subscription or online service; an invoice or receipt is needed.",
    "INSURANCE": "An insurance premium; a premium notice or invoice is needed.",
    "TAX": "A tax, duty or contribution paid to an authority; no invoice.",
    "PAYROLL": "Wages or an advance paid to an employee; no invoice.",
    "BANK_FEE": "A bank fee, interest or commission; no invoice.",
    "INTERNAL_TRANSFER": "A transfer between the company's own accounts; no invoice.",
    "LOAN": "A loan repayment; no invoice.",
    "CASH_WITHDRAWAL": "Cash taken out of the account (ATM or counter); no invoice.",
    "CUSTOMER_REFUND": "Money returned to one of the company's own customers, often citing the company's own invoice number; no supplier invoice.",
    "UNCERTAIN": "The text does not say what the payment was for.",
}

# Tasks that may not call out yet, with the reason. Empty since Balázs decided
# for the pairing (2026-10-01 04:38 UTC, Eldöntendő 1555039853165412364): it
# runs with redact.PAIRING_KEEP, business data in, personal data still out.
CALL_BLOCKED = {}

# The legal forms that make a partner a company. "ev." (egyéni vállalkozó) is
# NOT among them: a sole trader is a private person, and its name stays out.
_COMPANY = re.compile(
    r"(?i)(?<![^\W_])(kft|zrt|nyrt|bt|kkt|gmbh|ltd|limited|inc|llc|b\.?v|s\.?r\.?o|sas|sarl|ag|oy|ab|spa|srl|nv|plc|pbc)\.?(?![^\W_])")


def _private(name):
    """A partner without a legal form, and not a card merchant descriptor
    (SIMPLEP*PARKL.NET), counts as a private person: its name is masked here,
    before redaction, not left to the name detector (Balázs: on a transfer to
    a private person the partner's name stays out too)."""
    return bool(name) and not _COMPANY.search(name) and "*" not in name


def _masked(text, name):
    return text.replace(name, "<PRIVATE_PARTNER>") if name and _private(name) else text

LETTER_CLASSES = {
    "BEJOVO_SZAMLA": "An invoice issued TO the company by a supplier, Hungarian or foreign (Invoice, Rechnung, Facture, számla).",
    "NYUGTA": "A payment receipt that accompanies an invoice; not the invoice itself.",
    "DIJBEKERO": "A pro forma invoice or a request for advance payment (díjbekérő, Proforma Invoice).",
    "SAJAT_KIMENO": "An invoice issued BY the company to its own customer.",
    "SZALLITOLEVEL": "A delivery note (szállítólevél, Lieferschein, Delivery note).",
    "VISSZAIGAZOLAS": "An order confirmation, an offer or a booking confirmation.",
    "EMLEKEZTETO": "A payment reminder or dunning letter about an earlier invoice.",
    "EGYEB": "Anything else: contract, terms and conditions, notice, newsletter.",
}


def _log_path():
    return os.path.join(shadow.STORE, LOG_NAME)


# ------------------------------------------------------------ the texts
def payment_text(item):
    original = f" (original: {item['original']})" if item.get("original") else ""
    # lower-case field labels: a capitalised label reads as a proper name to the
    # redactor and comes back as <PROPER_n> noise (acrobot 25498)
    text = (f"Bank payment on {item['date']}: {item['amount']} {item['currency']}{original}; "
            f"partner: {item['partner']}; reference: {item['narrative']}; type: {item.get('type', '')}.")
    return _masked(text, item.get("partner", ""))


def candidate_text(candidate):
    text = (f"Invoice {candidate['number']}, issued {candidate['date']}, gross {candidate['gross']} "
            f"{candidate['currency']}, issuer: {candidate['supplier']}.")
    return _masked(text, candidate.get("supplier", ""))


def letter_text(item):
    return f"Subject: {item.get('subject', '')}\n{item.get('head', '')}"


# ------------------------------------------------------------ the requests
def build(task, item):
    """(RedactedDTO, questions, option_keys). Raises shadow.Blocked on any
    redaction or guard failure: a dropped measurement, never a raw call."""
    if task == "missing_invoice_pair":
        keep, allow = redact.PAIRING_KEEP, redact.PAIRING_KNOWN_ALLOW
        query = shadow._redacted_dto({"query": payment_text(item)}, {"query": MAX_QUERY_CHARS},
                                     keep_kinds=keep, allow_known_kinds=allow)
        cands = [shadow._redacted_dto({"candidate": candidate_text(c)}, {"candidate": MAX_CANDIDATE_CHARS},
                                      keep_kinds=keep, allow_known_kinds=allow)
                 for c in item["candidates"]]
        dto = shadow._combined_dto(query, cands, allow_known_kinds=allow)
        dto.input_hash = query.input_hash
        dto.counts = _sum_counts([query] + cands)
        criteria = {f"c{i}": f"The invoice in field c{i}." for i in range(len(cands))}
        criteria["NONE"] = "None of these invoices is the one this payment pays."
        questions = {"pair": {"type": "choice", "criteria": criteria, "instructions": (
            "'query' is one payment from the company's bank account. Each field c0, c1, ... is one "
            "invoice the company received from that partner. Which invoice does this payment pay? "
            "Compare the amount, the date and any invoice number in the reference.")}}
        return dto, questions, list(criteria)
    if task == "missing_invoice_category":
        dto = shadow._redacted_dto({"query": payment_text(item)}, {"query": MAX_QUERY_CHARS})
        questions = {"category": {"type": "choice", "criteria": dict(CATEGORIES), "instructions": (
            "'query' is one payment from the company's bank account. Which kind of payment is it, "
            "and does it need an invoice?")}}
        return dto, questions, list(CATEGORIES)
    if task == "letter_class":
        dto = shadow._redacted_dto({"message": letter_text(item)}, {"message": MAX_LETTER_CHARS})
        questions = {"kind": {"type": "choice", "criteria": dict(LETTER_CLASSES), "instructions": (
            "'message' is the start of one PDF that arrived in the company's mailbox, with the mail's "
            "subject. What kind of document is the PDF itself (not what the mail is about)?")}}
        return dto, questions, list(LETTER_CLASSES)
    raise shadow.Blocked("bad_task")


def _sum_counts(dtos):
    out = {}
    for d in dtos:
        for k, v in (d.counts or {}).items():
            out[k] = out.get(k, 0) + v
    return out


def _answer(r, options):
    answers = r.get("answers") or {}
    if len(answers) != 1:
        raise ValueError("answer_count")
    a = next(iter(answers.values()))
    choice = a.get("choice")
    if choice not in options:
        raise ValueError("answer_not_an_option")
    probs = {k: round(float(v), 4) for k, v in (a.get("probabilities") or {}).items() if k in options}
    return choice, round(float(a.get("confidence", 0)), 4), probs


# ------------------------------------------------------------ one item
def run_item(task, item, side, call, show=None):
    row = {"ts": int(time.time()), "task": task, "policy": POLICIES.get(task), "side": side,
           "item": str(item.get("id", ""))[:32], "redaction_version": redact.REDACTION_VERSION}
    try:
        if call and task in CALL_BLOCKED:
            raise shadow.Blocked("blocked_" + CALL_BLOCKED[task])
        if call and not shadow._gate_green():
            raise shadow.Blocked("blocked_leak_gate")
        dto, questions, options = build(task, item)
        row.update(input_hash=dto.input_hash, placeholders=dto.counts)
        if not call:
            row["outcome"] = "dry_run"
            if show is not None:
                show(item.get("id"), dto.fields)   # the redacted text, to the screen only
            return row
        row["outcome"] = "provider_called"
        r, ms = shadow._call_provider(dto, questions)
        choice, confidence, probs = _answer(r, options)
        row.update(model=r.get("model"), choice=choice, confidence=confidence,
                   probabilities=probs, latency_ms=ms,
                   input_tokens=(r.get("usage") or {}).get("input_tokens"))
    except shadow.Blocked as b:
        row["outcome"] = b.outcome
        if b.detail:
            row["detail"] = b.detail[:120]
    except (urllib.error.URLError, OSError, ValueError, KeyError, TimeoutError) as e:
        row.setdefault("outcome", "error_before_call")
        row["error"] = type(e).__name__ + (f":{e.code}" if hasattr(e, "code") else "") \
            + (f":{e}" if isinstance(e, ValueError) and str(e) in ("answer_count", "answer_not_an_option") else "")
    if call:
        with open(_log_path(), "a", encoding="utf-8") as f:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
    return row


# ------------------------------------------------------------ the dataset
def items_for(task, halmaz, felosztas, side):
    split = felosztas["tetelek"]
    if task == "missing_invoice_pair":
        pool = halmaz["A"]
    elif task == "missing_invoice_category":
        pool = halmaz["B"]
    else:
        pool = halmaz
    return [i for i in pool if split.get(i["id"]) == side]


def holdout_already_run(task):
    try:
        with open(_log_path(), encoding="utf-8") as f:
            for line in f:
                r = json.loads(line)
                if (r.get("side") == "HOLDOUT" and r.get("task") == task
                        and r.get("policy") == POLICIES[task] and r.get("outcome") == "provider_called"):
                    return True
    except FileNotFoundError:
        return False
    return False


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--task", required=True, choices=sorted(POLICIES))
    p.add_argument("--halmaz", required=True)
    p.add_argument("--felosztas", required=True)
    p.add_argument("--side", default="DEV", choices=["DEV", "HOLDOUT"])
    p.add_argument("--holdout-once", action="store_true")
    p.add_argument("--limit", type=int, default=0)
    p.add_argument("--call", action="store_true", help="really call the provider (default: dry run)")
    a = p.parse_args(argv)
    if a.call and a.task in CALL_BLOCKED:
        sys.exit(f"{a.task}: --call is blocked ({CALL_BLOCKED[a.task]}); only the dry run is allowed.")
    if a.side == "HOLDOUT":
        if not (a.call and a.holdout_once):
            sys.exit("HOLDOUT: only with --call --holdout-once, after tuning is over.")
        if holdout_already_run(a.task):
            sys.exit("HOLDOUT: already run for this task and policy; it runs once.")
    with open(a.halmaz, encoding="utf-8") as f:
        halmaz = json.load(f)
    with open(a.felosztas, encoding="utf-8") as f:
        felosztas = json.load(f)
    items = items_for(a.task, halmaz, felosztas, a.side)
    if a.limit:
        items = items[: a.limit]

    def show(item_id, fields):
        print(f"--- {item_id}")
        for name, text in fields.items():
            print(f"  [{name}] {text}")

    outcomes = {}
    for item in items:
        row = run_item(a.task, item, a.side, a.call, show=None if a.call else show)
        outcomes[row["outcome"]] = outcomes.get(row["outcome"], 0) + 1
    print(json.dumps({"task": a.task, "side": a.side, "items": len(items), "outcomes": outcomes}))


if __name__ == "__main__":
    main()
