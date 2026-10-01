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
import random
import re
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
# P-016 (prototype, not wired): one call per recall message instead of one per
# hit. A different prompt shape is a different policy, so reports can split.
POLICY_BATCH = "d005-shadow-v2"
MAX_BATCH = 11   # the hook sends the shown rows (<= 8) plus up to 3 below the cut
TIMEOUT = 60   # first real hour: 22 of 58 calls over 9 s, max 29.5 s, clustered 8 at a time
JOB_SECONDS = 75   # redaction plus call; past this the measurement is dropped
MAX_CANDIDATE_CHARS = 1500
MAX_MESSAGE_CHARS = 4000
MAX_REDACT_CHARS = 20000   # redact the whole text first, cut AFTER (nautilus 2026-09-28)
SALT_FILE = os.path.join(STORE, ".jev-hash-salt")


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


def _salt():
    try:
        with open(SALT_FILE, "rb") as f:
            return f.read()
    except FileNotFoundError:
        salt = os.urandom(16)
        fd = os.open(SALT_FILE, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(salt)
        return salt


def _input_hash(fields):
    return hashlib.blake2b(json.dumps(fields, sort_keys=True, ensure_ascii=False).encode(),
                           key=_salt(), digest_size=8).hexdigest()


def text_hash(text):
    """P-017: keyed hash of ONE exact text, so the blind-label sampler can find
    the query in the ledger and check that a candidate's source text is still
    the one that was judged. Same salt as input_hash; never reversible here."""
    return hashlib.blake2b(str(text).encode("utf-8"), key=_salt(), digest_size=8).hexdigest()


def _redacted_dto(fields, limits, keep_kinds=()):
    """Redacts each field in full and cuts the REDACTED text to its limit:
    a cut before redaction can split an email or a name so that no pattern
    recognises the remaining half."""
    raw_hash = _input_hash(fields)
    out, counts = {}, {}
    for name, value in fields.items():
        if len(value) > MAX_REDACT_CHARS:
            raise Blocked("blocked_too_long")
        try:
            r = redact.redact(value, keep_kinds=keep_kinds)
        except redact.RedactionError as e:
            raise Blocked("blocked_redaction_error", str(e))
        problems = redact.runtime_guard(r)
        if problems:
            raise Blocked("blocked_runtime_guard", ",".join(problems))
        cut = r["text"][: limits[name]]
        cut = re.sub(r"<[A-Z_]*\d*$", "", cut)   # never send half a placeholder
        out[name] = cut
        for k, v in r["counts"].items():
            counts[k] = counts.get(k, 0) + v
    return RedactedDTO(out, redact.REDACTION_VERSION, counts, raw_hash)


def _combined_dto(query_dto, candidate_dtos):
    """P-016: ONE provider request out of pieces that were each redacted and
    guarded on their own (the leak gate is measured per piece). It accepts
    only RedactedDTOs, re-runs the runtime guard on every piece it puts in,
    and never sees raw text. The result is still a RedactedDTO, so
    _call_provider's own check stays the last word."""
    parts = [query_dto] + list(candidate_dtos)
    if any(not isinstance(d, RedactedDTO) or d.version != redact.REDACTION_VERSION for d in parts):
        raise Blocked("blocked_not_redacted")
    fields = {"query": query_dto.fields["query"]}
    for i, d in enumerate(candidate_dtos):
        fields["c%d" % i] = d.fields["candidate"]
    for name, text in fields.items():
        problems = redact.runtime_guard({"text": text, "version": redact.REDACTION_VERSION})
        if problems:
            raise Blocked("blocked_runtime_guard", ",".join(problems))
    return RedactedDTO(fields, redact.REDACTION_VERSION, {}, "")


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


_LOCAL_TOKEN = re.compile(r"^[A-Za-z0-9_.:-]{0,40}$")


def _safe_local(local):
    """The caller's own verdict, for comparison. Only numbers, booleans and
    short code-like tokens pass; anything that could be text is dropped, so a
    hook cannot put a message into the log by accident (nautilus 2026-09-28)."""
    def ok(v):
        if isinstance(v, bool) or isinstance(v, (int, float)) or v is None:
            return True
        return isinstance(v, str) and bool(_LOCAL_TOKEN.match(v))
    if not isinstance(local, dict):
        return None
    out = {}
    for k, v in list(local.items())[:12]:
        if not (isinstance(k, str) and _LOCAL_TOKEN.match(k)):
            continue
        if isinstance(v, list):
            v = [x for x in v if ok(x)][:10]
        elif not ok(v):
            continue
        out[k] = v
    return out


def run_job(job):
    task = job.get("task")
    row = {"ts": int(time.time()), "task": task, "policy": POLICY,
           "redaction_version": redact.REDACTION_VERSION, "local": _safe_local(job.get("local"))}
    try:
        if not _enabled():
            raise Blocked("disabled")
        if not _gate_green():
            raise Blocked("blocked_leak_gate")
        if task == "memory":
            fields = {"query": str(job.get("query", "")), "candidate": str(job.get("candidate", ""))}
            limits = {"query": MAX_MESSAGE_CHARS, "candidate": MAX_CANDIDATE_CHARS}
            questions = MEMORY_Q
        elif task == "outgoing":
            fields = {"message": str(job.get("message", ""))}
            limits = {"message": MAX_MESSAGE_CHARS}
            questions = OUTGOING_Q
        else:
            raise Blocked("bad_task")
        dto = _redacted_dto(fields, limits)
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


# ACD-013 point 2: an optional, CLOSED reason code per candidate. It is asked
# as a second choice question, so the provider can only answer with one of
# these keys -- never free text, which the log may not hold.
REASON_CODES = {
    "SAME_SUBJECT": "The note is about the same subject as the query.",
    "SHARED_WORDS": "The note only shares words or names with the query.",
    "OTHER_SUBJECT": "The note is about a different subject.",
    "TOO_LITTLE_TEXT": "There is too little text to tell.",
}
WITH_REASON = False   # off by default: it doubles the questions per call


def memory_batch_questions(n, with_reason=None):
    """One 'rel' question per candidate field c0..c(n-1), same wording and
    criteria as MEMORY_Q (RELEVANT / NOT_RELEVANT / UNCERTAIN), so the answers
    stay comparable with v1; optionally one closed 'why' question each."""
    with_reason = WITH_REASON if with_reason is None else with_reason
    base = MEMORY_Q["rel"]
    q = {}
    for i in range(n):
        q["rel_%d" % i] = {
            "type": "choice",
            "instructions": ("An assistant is about to answer 'query'. 'c%d' is one stored note "
                             "from its memory. Would reading this note change or inform the answer?" % i),
            "criteria": dict(base["criteria"])}
        if with_reason:
            q["why_%d" % i] = {
                "type": "choice",
                "instructions": "Which best describes how 'c%d' relates to 'query'?" % i,
                "criteria": dict(REASON_CODES)}
    return q


def _valid_choice(v, allowed):
    if not isinstance(v, dict) or v.get("choice") not in allowed:
        return None
    c = v.get("confidence", 0)
    if isinstance(c, bool) or not isinstance(c, (int, float)):
        return None
    return {"choice": v.get("choice"), "confidence": round(float(c), 4)}


_BATCH_DETAILS = ("shape", "missing", "extra")


def _check_batch(answers, asked):
    """ACD-013 point 1: the batch is valid only as a WHOLE. Any missing key,
    any unrequested key, or any answer of the wrong shape makes every row of
    the call unusable. Returns (parsed, problems); problems is a subset of
    _BATCH_DETAILS, never text from the response."""
    problems = set()
    if not isinstance(answers, dict):
        return {}, {"shape"}
    parsed = {}
    for key, allowed in asked.items():
        if key not in answers:
            problems.add("missing")
            continue
        a = _valid_choice(answers[key], allowed)
        if a is None:
            problems.add("shape")
        else:
            parsed[key] = a
    if any(k not in asked for k in answers):
        problems.add("extra")
    return parsed, problems


_shuffle = random.SystemRandom().shuffle


def run_batch(job):
    """P-016 / ACD-013: one provider call for all candidates of one recall
    message.

    Log shape is the SAME as for single memory jobs -- one row per candidate,
    task "memory" -- so the report reads it, with these additions:
      policy       d005-shadow-v2 (different prompt shape; reports keep v1 apart)
      call_id      random hex shared by the rows of one call (no text)
      batch_size / batch_index   (batch_index = position in the INPUT)
    latency_ms, input_tokens and model sit on the FIRST called row only, so
    one call is not read as N calls and N times the tokens.

    CANDIDATE KEYS c0..cN ARE OPAQUE: the candidates go into the call in a
    RANDOM order, so a key carries neither rank nor store (ACD-013 point 3;
    in rank order c0 would always be the best-ranked hit). The answers are
    mapped back by key.

    Each candidate is redacted and guarded on its own; one that fails is
    logged with its own outcome and left out of the call. The ANSWERS are
    valid only as a whole (ACD-013 point 1): a missing key, an extra key or a
    malformed answer marks every called row batch_invalid, without answers."""
    query = str(job.get("query", ""))
    # the exact text the ledger stores (outgoing: tool_input text, unstripped)
    query_exact = job.get("query_exact") if isinstance(job.get("query_exact"), str) else query
    cands = job.get("candidates") if isinstance(job.get("candidates"), list) else []
    cands = cands[:MAX_BATCH]
    ts = int(time.time())
    rows = [{"ts": ts, "task": "memory", "policy": POLICY_BATCH,
             "redaction_version": redact.REDACTION_VERSION,
             "local": _safe_local(c.get("local") if isinstance(c, dict) else None),
             "batch_size": len(cands), "batch_index": i} for i, c in enumerate(cands)]

    def finish(outcome, detail="", only=None):
        for i, row in enumerate(rows):
            if (only is None or i in only) and "outcome" not in row:
                row["outcome"] = outcome
                if detail:
                    row["detail"] = detail[:120]
        for row in rows:
            _log(row)
        return rows

    if not rows:
        return rows
    if not _enabled():
        return finish("disabled")
    if not _gate_green():
        return finish("blocked_leak_gate")
    try:
        qh = text_hash(query_exact)
        for row, c in zip(rows, cands):
            row["query_hash"] = qh
            row["cand_hash"] = text_hash(str(c.get("candidate", "")) if isinstance(c, dict) else "")
    except OSError:
        pass   # no salt file: the rows go without the P-017 hashes, nothing else changes
    try:
        qdto = _redacted_dto({"query": query}, {"query": MAX_MESSAGE_CHARS})
    except Blocked as b:
        return finish(b.outcome, b.detail)
    ok = []   # (row index, candidate dto)
    for i, c in enumerate(cands):
        text = str(c.get("candidate", "")) if isinstance(c, dict) else ""
        try:
            d = _redacted_dto({"candidate": text}, {"candidate": MAX_CANDIDATE_CHARS})
        except Blocked as b:
            rows[i]["outcome"] = b.outcome
            if b.detail:
                rows[i]["detail"] = b.detail[:120]
            continue
        rows[i]["input_hash"] = _input_hash({"query": query, "candidate": text})
        counts = dict(qdto.counts)
        for k, v in d.counts.items():
            counts[k] = counts.get(k, 0) + v
        rows[i]["placeholders"] = counts
        ok.append((i, d))
    if not ok:
        return finish("blocked_redaction_error")
    _shuffle(ok)   # the key cK no longer follows the input (= rank) order
    try:
        dto = _combined_dto(qdto, [d for _, d in ok])
    except Blocked as b:
        return finish(b.outcome, b.detail, only={i for i, _ in ok})
    call_id = os.urandom(6).hex()
    for i, _ in ok:
        rows[i]["outcome"] = "provider_called"
        rows[i]["call_id"] = call_id
    first = rows[min(i for i, _ in ok)]
    with_reason = WITH_REASON
    try:
        r, ms = _call_provider(dto, memory_batch_questions(len(ok), with_reason))
    except Blocked as b:
        for i, _ in ok:
            rows[i]["outcome"] = b.outcome
        return finish(b.outcome)
    except (urllib.error.URLError, OSError, ValueError, KeyError, TimeoutError) as e:
        err = type(e).__name__ + (f":{e.code}" if hasattr(e, "code") else "")
        for i, _ in ok:
            rows[i]["error"] = err
        return finish("provider_called")
    first.update(model=r.get("model"), latency_ms=ms,
                 input_tokens=(r.get("usage") or {}).get("input_tokens"))
    asked = {}
    for k in range(len(ok)):
        asked["rel_%d" % k] = MEMORY_Q["rel"]["criteria"]
        if with_reason:
            asked["why_%d" % k] = REASON_CODES
    parsed, problems = _check_batch(r.get("answers"), asked)
    if problems:
        detail = ",".join(p for p in _BATCH_DETAILS if p in problems)
        for i, _ in ok:
            rows[i]["outcome"] = "batch_invalid"
            rows[i]["detail"] = detail
        return finish("batch_invalid")
    for k, (i, _) in enumerate(ok):
        rows[i]["answers"] = {"rel": parsed["rel_%d" % k]}
        if with_reason:
            rows[i]["answers"]["reason"] = parsed["why_%d" % k]["choice"]
    return finish("provider_called")


def submit_batch(query, candidates, query_exact=None):
    """For the recall hook under P-016: one detached child per message.
    query_exact (P-017): the text as the ledger stores it, for query_hash."""
    job = {"task": "memory_batch", "query": query, "candidates": candidates}
    if query_exact is not None:
        job["query_exact"] = query_exact
    submit(job)


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
        import signal
        job = json.loads(sys.stdin.read())

        def _timeout(*_):
            if job.get("task") == "memory_batch":
                cands = (job.get("candidates") or [])[:MAX_BATCH]
                for i, c in enumerate(cands):
                    _log({"ts": int(time.time()), "task": "memory", "policy": POLICY_BATCH,
                          "redaction_version": redact.REDACTION_VERSION, "outcome": "blocked_timeout",
                          "local": _safe_local(c.get("local") if isinstance(c, dict) else None),
                          "batch_size": len(cands), "batch_index": i})
            else:
                _log({"ts": int(time.time()), "task": job.get("task"), "policy": POLICY,
                      "redaction_version": redact.REDACTION_VERSION, "outcome": "blocked_timeout"})
            os._exit(0)
        signal.signal(signal.SIGALRM, _timeout)
        signal.alarm(JOB_SECONDS)
        if job.get("task") == "memory_batch":
            run_batch(job)
        else:
            run_job(job)
    elif "--report" in sys.argv:
        print(json.dumps(report(), ensure_ascii=False, indent=1))
    else:
        print(__doc__)
