#!/usr/bin/env python3
# ANSWERS: Mit mondana a Jev egy emlek relevanciajarol vagy egy kimeno uzenetrol, ha megkerdeznenk (D-005 HIDDEN shadow, csak meres, semmit nem valtoztat)?
"""D-005 HIDDEN shadow client (PD-006: P-014 + P-015).

Nothing here changes what the fleet does. The hooks hand a job to
submit(), which returns immediately; a detached child redacts, checks,
maybe calls Jev, and writes one raw-text-free line to the shadow log.

Every path to the provider goes through _call_provider(), and that
function accepts only a RedactedDTO. A RedactedDTO is built only by
_redacted_dto(), which runs redact() and the runtime guard. There is no
code path that builds a provider request from raw text, and no fallback:
any failure is a dropped measurement, never an unredacted call.

Preconditions for a provider call, all of them, checked per job:
  1. kill switch on:   store/jev-shadow.json {"enabled": true}  (default OFF)
  2. leak gate green for THIS code: store/jev-leak-gate.json matches
     the redaction version and the hash of the redactor files
  3. redact() succeeded for every text field
  4. runtime_guard() found nothing

Log: store/jev-shadow.jsonl. Fields: ts, task, outcome, redaction version,
input hash, placeholder counts, model, decision, confidence, latency, error,
local verdict (the fleet's own decision, for comparison). Never text.
"""
import hashlib
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
import redact  # noqa: E402

STORE = os.environ.get("JEV_STORE", "/home/marveen/marveen/store")
SWITCH = os.path.join(STORE, "jev-shadow.json")
GATE = os.environ.get("JEV_LEAK_GATE_STATUS", os.path.join(STORE, "jev-leak-gate.json"))
LOG = os.path.join(STORE, "jev-shadow.jsonl")
KEY_FILE = os.path.join(STORE, ".jev-api-key")
ENDPOINT = "https://api.typesafe.ai/v1/systemone"
MODEL = "jev-1.13.0"   # pinned; old versions stop answering (memory 1883)
POLICY = "d005-shadow-v1"
TIMEOUT = 8
MAX_CANDIDATE_CHARS = 1500
MAX_MESSAGE_CHARS = 4000


class RedactedDTO:
    """The only thing _call_provider() accepts. Built only by _redacted_dto()."""
    __slots__ = ("fields", "version", "counts", "input_hash")

    def __init__(self, fields, version, counts, input_hash):
        self.fields, self.version = fields, version
        self.counts, self.input_hash = counts, input_hash


class Blocked(Exception):
    def __init__(self, outcome, detail=""):
        super().__init__(outcome)
        self.outcome, self.detail = outcome, detail


# ------------------------------------------------------------ preconditions
def _enabled():
    try:
        with open(SWITCH) as f:
            return json.load(f).get("enabled") is True
    except (OSError, ValueError, AttributeError):
        return False


def _gate_green():
    try:
        import leak_gate
        with open(GATE) as f:
            g = json.load(f)
        return (g.get("leaks") == 0
                and g.get("redaction_version") == redact.REDACTION_VERSION
                and g.get("code_hash") == leak_gate.code_hash())
    except Exception:
        return False


def _redacted_dto(fields):
    raw_hash = hashlib.sha256(json.dumps(fields, sort_keys=True, ensure_ascii=False)
                              .encode()).hexdigest()[:16]
    out, counts = {}, {}
    for name, value in fields.items():
        try:
            r = redact.redact(value)
        except redact.RedactionError as e:
            raise Blocked("blocked_redaction_error", str(e))
        problems = redact.runtime_guard(r)
        if problems:
            raise Blocked("blocked_runtime_guard", ",".join(problems))
        out[name] = r["text"]
        for k, v in r["counts"].items():
            counts[k] = counts.get(k, 0) + v
    return RedactedDTO(out, redact.REDACTION_VERSION, counts, raw_hash)


# ------------------------------------------------------------ provider
def _call_provider(dto, questions):
    if not isinstance(dto, RedactedDTO) or dto.version != redact.REDACTION_VERSION:
        raise Blocked("blocked_not_redacted")
    key = open(KEY_FILE).read().strip()
    body = {"state": dto.fields, "model": MODEL, "questions": questions}
    req = urllib.request.Request(ENDPOINT, data=json.dumps(body).encode(), method="POST",
                                 headers={"Authorization": "Bearer " + key,
                                          "Content-Type": "application/json"})
    t = time.time()
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        r = json.load(resp)
    return r, int((time.time() - t) * 1000)


# ------------------------------------------------------------ tasks
MEMORY_Q = {"rel": {
    "type": "choice",
    "instructions": ("An assistant is about to answer 'query'. 'candidate' is one stored note "
                     "from its memory. Would reading this note change or inform the answer?"),
    "criteria": {
        "RELEVANT": "The note is about the same subject and would inform the answer.",
        "NOT_RELEVANT": "The note only shares words; it is about something else.",
        "UNCERTAIN": "Cannot tell from the text given.",
    }}}

YN = {"YES": None, "NO": None}
OUTGOING_Q = {
    "defer": {"type": "choice", "criteria": YN, "instructions":
              "Does this message postpone work to a later time (tomorrow, morning, later, next time) "
              "instead of doing it now, including indirect phrasing?"},
    "reopen": {"type": "choice", "criteria": YN, "instructions":
               "Does this message ask the reader to decide something again that reads as already "
               "decided or discussed?"},
    "jargon": {"type": "choice", "criteria": YN, "instructions":
               "Does this message ask the reader a question that can only be understood with "
               "internal technical terms (table, field, relation, endpoint, schema)?"},
    "multi": {"type": "choice", "criteria": YN, "instructions":
              "Does this message ask the reader more than one separate question?"},
}


def _answers(r):
    a = r.get("answers") or {}
    return {k: {"choice": v.get("choice"), "confidence": round(float(v.get("confidence", 0)), 4)}
            for k, v in a.items()}


def run_job(job):
    task = job.get("task")
    row = {"ts": int(time.time()), "task": task, "policy": POLICY,
           "redaction_version": redact.REDACTION_VERSION, "local": job.get("local")}
    try:
        if not _enabled():
            raise Blocked("disabled")
        if not _gate_green():
            raise Blocked("blocked_leak_gate")
        if task == "memory":
            fields = {"query": str(job.get("query", ""))[:MAX_MESSAGE_CHARS],
                      "candidate": str(job.get("candidate", ""))[:MAX_CANDIDATE_CHARS]}
            questions = MEMORY_Q
        elif task == "outgoing":
            fields = {"message": str(job.get("message", ""))[:MAX_MESSAGE_CHARS]}
            questions = OUTGOING_Q
        else:
            raise Blocked("bad_task")
        dto = _redacted_dto(fields)
        row.update(input_hash=dto.input_hash, placeholders=dto.counts)
        row["outcome"] = "provider_called"
        r, ms = _call_provider(dto, questions)
        row.update(model=r.get("model"), answers=_answers(r), latency_ms=ms,
                   input_tokens=(r.get("usage") or {}).get("input_tokens"))
    except Blocked as b:
        row["outcome"] = b.outcome
        if b.detail:
            row["detail"] = b.detail[:120]
    except (urllib.error.URLError, OSError, ValueError, KeyError, TimeoutError) as e:
        # outcome stays provider_called when the call itself failed
        row.setdefault("outcome", "error_before_call")
        row["error"] = type(e).__name__ + (f":{e.code}" if hasattr(e, "code") else "")
    _log(row)
    return row


def _log(row):
    try:
        fd = os.open(LOG, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        with os.fdopen(fd, "a", encoding="utf-8") as f:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
    except OSError:
        pass


def submit(job):
    """For hooks: never blocks, never raises, never changes a verdict. The
    job (which holds raw text) goes to a detached child over a pipe, so it
    never touches disk or a command line. When the switch is off, not even
    a child is started."""
    try:
        if not _enabled():
            return
        p = subprocess.Popen([sys.executable, os.path.abspath(__file__), "--job"],
                             stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True)
        p.stdin.write(json.dumps(job, ensure_ascii=False).encode())
        p.stdin.close()
    except Exception:
        pass


def report(since=0):
    """Redaction and decision metrics block (ACD-011 point 5)."""
    rows = []
    try:
        with open(LOG, encoding="utf-8") as f:
            rows = [json.loads(line) for line in f if line.strip()]
    except OSError:
        pass
    rows = [r for r in rows if r.get("ts", 0) >= since]
    out = {"attempted": len(rows), "by_outcome": {}, "by_task": {}, "placeholders": {},
           "redaction_versions": sorted({r.get("redaction_version") for r in rows if r.get("redaction_version")})}
    for r in rows:
        out["by_outcome"][r.get("outcome")] = out["by_outcome"].get(r.get("outcome"), 0) + 1
        out["by_task"][r.get("task")] = out["by_task"].get(r.get("task"), 0) + 1
        for k, v in (r.get("placeholders") or {}).items():
            out["placeholders"][k] = out["placeholders"].get(k, 0) + v
    out["provider_called"] = out["by_outcome"].get("provider_called", 0)
    out["redacted_ok"] = sum(1 for r in rows if "placeholders" in r)
    return out


if __name__ == "__main__":
    if "--job" in sys.argv:
        run_job(json.loads(sys.stdin.read()))
    elif "--report" in sys.argv:
        print(json.dumps(report(), ensure_ascii=False, indent=1))
    else:
        print(__doc__)
