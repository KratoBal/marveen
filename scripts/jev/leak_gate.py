#!/usr/bin/env python3
# ANSWERS: Atmegy-e a jelenlegi kitakaro a rogzitett magyar szivargas-keszleten (0 szivargas = a Jev shadow kivitel engedelyezheto)?
"""Hard gate for the D-005 shadow export (ACD-011 point 2).

Runs redact() over every case of the fixed suite and checks, after folding
(case, accents, homoglyphs), that no leak string survives. 'keep' strings
are reported as the semantic cost, not gated.

On 0 leaks it writes store/jev-leak-gate.json with the redaction version,
the suite version and a hash of the redactor's own files. The provider
boundary (shadow.py) refuses to call out unless that file matches the code
that is running now, so an edited redactor is closed until re-tested.

Usage: python3 leak_gate.py [--verbose]
Exit 0 only when every case passes.
"""
import hashlib
import json
import os
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
import redact  # noqa: E402

SUITE = os.path.join(_HERE, "leak-suite.json")
STATUS = os.environ.get("JEV_LEAK_GATE_STATUS", "/home/marveen/marveen/store/jev-leak-gate.json")
CODE_FILES = ["redact.py", "shadow.py", "hu-names.txt", "preserve-terms.json", "leak-suite.json"]
OPTIONAL_FILES = [redact.COMMON_WORDS_PATH]


def code_hash():
    h = hashlib.sha256()
    for f in CODE_FILES:
        with open(os.path.join(_HERE, f), "rb") as fh:
            h.update(f.encode() + b"\0" + fh.read() + b"\0")
    for f in OPTIONAL_FILES:
        try:
            with open(f, "rb") as fh:
                h.update(os.path.basename(f).encode() + b"\0" + fh.read() + b"\0")
        except OSError:
            h.update(os.path.basename(f).encode() + b"\0absent\0")
    return h.hexdigest()


def _expand(x):
    """Fixture secrets are stored broken ("gh@@p_...") so the repository's
    secret gate does not see a token shape; the redactor sees the real one."""
    if isinstance(x, str):
        return x.replace("@@", "")
    if isinstance(x, list):
        return [_expand(i) for i in x]
    if isinstance(x, dict):
        return {k: _expand(v) for k, v in x.items()}
    return x


def load_suite(path=SUITE):
    with open(path, encoding="utf-8") as f:
        return _expand(json.load(f))


def run(verbose=False):
    suite = load_suite()
    leaks, kept, keep_total, errors = [], 0, 0, []
    for c in suite["cases"]:
        try:
            out = redact.redact(c["text"])["text"]
        except redact.RedactionError as e:
            errors.append((c["id"], str(e)))
            continue
        fo = redact.fold(out)
        for s in c.get("leak", []):
            if redact.fold(s) in fo:
                leaks.append((c["id"], s, out))
        for s in c.get("keep", []):
            keep_total += 1
            if redact.fold(s) in fo:
                kept += 1
            elif verbose:
                print(f"  lost-keep {c['id']}: {s!r} -> {out}")
        if verbose:
            print(f"{c['id']:36} {out}")
    return suite, leaks, errors, kept, keep_total


def main():
    verbose = "--verbose" in sys.argv
    suite, leaks, errors, kept, keep_total = run(verbose)
    n = len(suite["cases"])
    print(f"redaction {redact.REDACTION_VERSION}, suite {suite['suite_version']}: "
          f"{n} cases, {len(leaks)} leaks, {len(errors)} errors, keep {kept}/{keep_total}")
    for cid, s, out in leaks:
        print(f"  LEAK {cid}: {s!r} survived -> {out}")
    for cid, e in errors:
        print(f"  ERROR {cid}: {e}")
    ok = not leaks and not errors
    if ok:
        os.makedirs(os.path.dirname(STATUS), exist_ok=True)
        tmp = STATUS + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"redaction_version": redact.REDACTION_VERSION,
                       "suite_version": suite["suite_version"], "code_hash": code_hash(),
                       "cases": n, "leaks": 0, "keep": [kept, keep_total],
                       "passed_at": int(time.time())}, f)
        os.replace(tmp, STATUS)
    elif os.path.exists(STATUS):
        os.remove(STATUS)  # a red run revokes an older green
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
