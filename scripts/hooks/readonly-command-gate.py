#!/usr/bin/env python3
"""PreToolUse gate: auto-allow read-only shell commands that only fail today
because they contain a shell VARIABLE.

WHY THIS EXISTS (acrobot brief, 2026-09-23, kanban -- barracuda 25 stops).
barracuda's profile runs in strict mode. Claude Code's own permission engine
refuses ANY Bash command that contains a variable expansion ("Contains
simple_expansion"), REGARDLESS of what is on the allow-list, because static
analysis cannot resolve what the variable will hold at run time. barracuda's
real, daily work is exactly this shape: `/bin/grep -vP mintat "$S/a.tsv"`,
where `$S` is a location-scoped scratch path he set earlier in the same
session. The command is genuinely read-only; only the variable trips the
generic engine.

THE FIX THAT WAS REJECTED FIRST, AND WHY: switching the profile to permissive
mode (`--dangerously-skip-permissions`) also bypasses the DENY list
(src/web/profiles.ts says so), and barracuda's deny list blocks store/**
(live Coolify tokens, DB passwords, the Medusa master key) and
.channels-config/** (channel credentials). Permissive mode would open those
too. Rejected.

THE APPROACH HERE: a narrow, additive PreToolUse hook. It looks at ONLY the
Bash tool, and only ever emits an explicit "allow" decision -- never "deny".
Every command it does not confidently recognise as read-only falls straight
through with NO output, which means Claude Code's own engine decides exactly
as it does today (ask, or allow via the profile's own allow-list). A wrong
call by this gate therefore costs one extra confirmation, never a silent
bypass and never a new block.

THREE CONDITIONS, ALL REQUIRED, PER SEGMENT (contract given by acrobot):

  1. Every segment's program is on a narrow read-only allow-list, DERIVED
     AT RUNTIME from templates/profiles/researcher-reader.json's own
     `filesystem.allow` array (see `read_only_binaries_from_profile`) --
     never a hand-typed second copy. `find` and `sed` get an extra,
     command-specific safety check (see below) because their PRESENCE on
     the allow-list does not mean every invocation of them is read-only.
  2. Every ${VAR}/$VAR reference in every argument must be resolvable
     from a SIMPLE "NAME=value" assignment earlier in the SAME command
     block (barracuda's actual shape: `S=/tmp/.../scratch` on its own
     line, then the real command below it -- see
     `_pure_assignment_tokens`/`_resolve_or_flag`). If a variable cannot
     be resolved this way, the WHOLE command fails condition 2 and the
     gate does not intervene (acrobot's explicit rule, 2026-09-23: an
     unresolved variable must fall back to asking, never pass on the
     strength of whatever literal text happens to remain). Once resolved
     (or if the argument never referenced a variable at all), the text is
     checked against a literal deny-listed path fragment (store/,
     .channels-config/, .env, .ssh/, .aws/, .gnupg/), read from the SAME
     profile file's `filesystem.deny` array.
  3. No side effect or hidden execution: no output redirection (`>`,
     `>>`), no `sed -i` / `sed --in-place`, no command substitution
     (`$(...)`, backtick), and every `;`/`&&`/`||`/`|`/newline-joined
     segment must independently satisfy conditions 1 and 2 (a chain to
     something NOT on the list, or to an unresolvable variable, fails the
     whole command).

WHAT THIS STILL DOES NOT AND CANNOT PROVE, STATED PLAINLY: even a
same-block assignment (`S=/tmp/x`) is trusted at face value -- this gate
does not re-derive where that value itself came from, and a value that
is itself unusual (assigned from something outside the visible block) is
exactly the case condition 2 refuses to resolve. What is now closed: a
BARE `"$S/a.tsv"` with NO assignment anywhere in the block no longer
auto-allows on the strength of the literal remainder after stripping --
it now correctly falls through to ask, same as any other unverifiable
input. That is why scope is barracuda only, and why the caller (acrobot)
is asked to sign off on this specific tradeoff before it goes live -- see
the kanban card this ships with.

HOOK CONTRACT (matched against scripts/hooks/outgoing-copy-gate.py, the
PreToolUse example in this repo). CORRECTED 2026-09-23 by nautilus: an
earlier draft of this paragraph also named prior-art-recall.py as a
PreToolUse example -- it is NOT, its own docstring says UserPromptSubmit,
and its output shape is additionalContext, not a permissionDecision. The
two events take different stdin and produce different stdout, so copying
from the wrong one silently produces a hook that never decides anything.
stdin carries {"tool_name": ..., "tool_input": {...}}. To
AUTO-ALLOW, print one line of JSON to stdout:

    {"hookSpecificOutput": {"hookEventName": "PreToolUse",
                             "permissionDecision": "allow",
                             "permissionDecisionReason": "..."}}

and exit 0. To leave the decision to the normal flow (uncertain, risky, or
not a Bash call at all), print NOTHING and exit 0 -- this is deliberately
the same "do nothing" shape as a hook that never ran, so a bug here degrades
to today's behaviour, never to a block and never to a silent bypass.
"""
import json
import os
import re
import shlex
import sys

def _install_dir():
    """The marveen install root, derived from THIS FILE'S OWN location, not
    from $HOME. Same pattern as scripts/hooks/provenance-gate.py's
    _install_dir(): when this hook runs, $HOME is the CALLING AGENT's own
    home (e.g. /home/agent-barracuda), never the shared install root --
    measured directly, by running this script as a subprocess under
    agent-murena's own $HOME and finding the profile file silently
    unreadable, which is worse than a loud failure, since a "not found"
    profile makes `decide()` return None just like a genuinely unsafe
    command would, and the two look identical from the outside."""
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


PROFILE_PATH_DEFAULT = os.path.join(
    _install_dir(), "templates", "profiles", "researcher-reader.json",
)

_ENV_ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")

# find/-exec family: any of these turn a "read-only" find into a write or an
# arbitrary-command execution. Presence of ANY of these anywhere in a find
# segment disqualifies that segment, full stop.
_FIND_DANGEROUS_FLAGS = {
    "-exec", "-execdir", "-delete", "-fprintf", "-ok", "-okdir", "-fls",
}

# sed: short-option bundles can hide -i (e.g. "-ni"). Anything starting with
# exactly one "-" (not "--") that contains the letter "i" is treated as
# carrying -i, which is a conservative over-match FOR SED SPECIFICALLY (sed
# has no other short flag that uses "i"), never an under-match.
_SED_LONG_INPLACE = re.compile(r"^--in-place(=.*)?$")


def _basename(tok: str) -> str:
    return tok.rsplit("/", 1)[-1]


def read_only_binaries_from_profile(profile: dict) -> set:
    """The set of program names/paths this gate treats as read-only,
    derived from the profile's OWN filesystem.allow list -- not a second,
    hand-typed copy (acrobot's explicit condition A). Only entries of the
    exact shape `Bash(<prog>:*)` are taken, and only for a fixed set of
    known-read-only coreutils; the profile also allow-lists specific
    scripts (jsonl.sh, unas.sh, ...) that this gate deliberately does NOT
    grant, because their internals are not visible to a static command-line
    check (unas.sh itself has a documented write path, `post_write`).
    """
    KNOWN_READ_ONLY = {
        "ls", "cat", "grep", "head", "tail", "wc", "sort", "uniq", "cut",
        "sed", "stat", "file", "md5sum", "tr", "nl", "pwd", "echo", "date",
        "df", "ps", "find",
    }
    out = set()
    for rule in profile.get("filesystem", {}).get("allow", []):
        m = re.match(r"^Bash\(([^:]+):\*\)$", rule)
        if not m:
            continue
        prog = m.group(1).strip()
        # "sed -n" and "find ${AGENT_DIR}" etc: take the leading program
        # token, drop the rest (per-command scoping is enforced separately,
        # not derived from this string).
        prog_tok = prog.split()[0]
        if _basename(prog_tok) in KNOWN_READ_ONLY:
            out.add(prog_tok)
            out.add(_basename(prog_tok))
    return out


def deny_fragments_from_profile(profile: dict) -> list:
    """The path-SEGMENT names (not full absolute paths) that must not
    appear anywhere in any argument. Taken from filesystem.deny -- the SAME
    file the profile itself is built from, so a change there is not a
    second place to edit. Only Read()/Write()/Edit() path rules are used;
    Bash(...) deny rules (sudo, rm, git push, curl -X POST, sed -i) are
    enforced by the syntax checks below, not by path matching.

    DELIBERATELY NOT anchored to the resolved ${HOME} absolute prefix. The
    real threat is "an argument reaches into store/ or .channels-config/ AT
    ALL", from whatever base a variable happens to expand to -- acrobot's
    own test cases use `<barmi>/store/...` (ANY prefix). Anchoring to
    "/home/marveen/marveen/store/" would miss "/whatever/store/x" and
    "$S/store/x" alike, which is exactly the gap a variable-tolerant check
    must not have. Matching is done on PATH-SEGMENT boundaries (see
    `_matches_deny_fragment`), not a raw substring, so "restore/x" does not
    false-positive on "store".
    """
    out = []
    for rule in profile.get("filesystem", {}).get("deny", []):
        m = re.match(r"^(?:Read|Write|Edit)\((.+)\)$", rule)
        if not m:
            continue
        pattern = m.group(1).replace("${HOME}", "")
        # Drop leading globs/slashes and trailing globs, keep the last
        # meaningful path segment: ".channels-config/**" -> ".channels-config",
        # "store/**" -> "store", "**/.env" -> ".env", ".env" -> ".env".
        stem = re.sub(r"^\*+/?", "", pattern)
        stem = re.sub(r"/?\*+$", "", stem)
        stem = stem.strip("/")
        segment = stem.rsplit("/", 1)[-1] if stem else ""
        if segment:
            out.append(segment)
    return out


def _matches_deny_fragment(token: str, fragment: str) -> bool:
    """True if `fragment` appears in `token` as a full path segment
    (bounded by "/" or the ends of the string), not merely as a substring
    -- so "store" catches "/x/store/y" and "store/y" but not "restore/y"."""
    return re.search(
        r"(^|/)" + re.escape(fragment) + r"(/|$)", token
    ) is not None


def _split_top_level(cmd: str):
    """Quote-aware split on top-level ; && || |, AND a hard reject if a
    forbidden metacharacter ($( backtick > ) appears outside single quotes.
    Double quotes do NOT protect $(...) or backticks from the real shell,
    so they are scanned too -- only single-quoted text is truly inert.
    Returns (segments, forbidden) where forbidden is True if scanning must
    stop and the whole command must be treated as unsafe.
    """
    segments = []
    cur = []
    i, n = 0, len(cmd)
    q = None  # None | "'" | '"'
    while i < n:
        ch = cmd[i]
        if q:
            if ch == "\\" and q == '"' and i + 1 < n:
                cur.append(cmd[i:i + 2])
                i += 2
                continue
            if ch == q:
                q = None
            cur.append(ch)
            i += 1
            continue
        if ch == "'":
            q = ch
            cur.append(ch)
            i += 1
            continue
        if ch == '"':
            q = ch
            cur.append(ch)
            i += 1
            continue
        if ch == "\\" and i + 1 < n:
            cur.append(cmd[i:i + 2])
            i += 2
            continue
        # forbidden metacharacters, unquoted
        if ch == "`":
            return None, True
        if ch == "$" and i + 1 < n and cmd[i + 1] == "(":
            return None, True
        if ch == ">":
            return None, True
        # segment separators. A bare newline is shell-equivalent to ";"
        # (sequential execution) -- acrobot's real barracuda example is a
        # variable assignment on its own line followed by the command that
        # uses it, so a newline must split into segments, not reject
        # outright. Each resulting segment is still independently checked.
        if ch == "|" and i + 1 < n and cmd[i + 1] == "|":
            segments.append("".join(cur)); cur = []; i += 2; continue
        if ch == "&" and i + 1 < n and cmd[i + 1] == "&":
            segments.append("".join(cur)); cur = []; i += 2; continue
        if ch in ("|", ";", "\n"):
            segments.append("".join(cur)); cur = []; i += 1; continue
        if ch == "&":
            # background execution (single &): not a read shape either.
            return None, True
        cur.append(ch)
        i += 1
    if q is not None:
        # unterminated quote -- cannot reason about it, refuse to auto-allow
        return None, True
    segments.append("".join(cur))
    return segments, False


def _sed_has_inplace(tokens) -> bool:
    for t in tokens:
        if _SED_LONG_INPLACE.match(t):
            return True
        if t.startswith("-") and not t.startswith("--") and "i" in t[1:]:
            return True
    return False


def _find_has_danger(tokens) -> bool:
    return any(t in _FIND_DANGEROUS_FLAGS for t in tokens)


_VAR_REF = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)")
_SIMPLE_ASSIGNMENT_VALUE = re.compile(r"^[^$`]*$")  # no nested variable, no substitution


def _pure_assignment_tokens(tokens):
    """If EVERY token in a segment is a NAME=value assignment, return the
    list of (name, value) pairs; otherwise None. A segment like this is a
    shell variable-definition statement on its own, not a command."""
    if not tokens or not all(_ENV_ASSIGN.match(t) for t in tokens):
        return None
    pairs = []
    for t in tokens:
        name, value = t.split("=", 1)
        pairs.append((name, value))
    return pairs


def _resolve_or_flag(token: str, bindings: dict):
    """Substitutes every ${VAR}/$VAR reference using `bindings` (name ->
    resolved string). Returns (resolved_text, ok). ok is False the moment
    ANY variable reference in the token is NOT a known, simply-assigned
    binding from EARLIER in the same command block -- per acrobot's rule,
    an unresolved variable must make the gate fall back to asking, not
    silently pass on the strength of whatever literal text remains after
    stripping it out.
    """
    ok = True

    def repl(m):
        nonlocal ok
        name = m.group(1) or m.group(2)
        if name not in bindings:
            ok = False
            return ""
        return bindings[name]

    resolved = _VAR_REF.sub(repl, token)
    return resolved, ok


def _segment_is_readonly(segment: str, safe_bins: set, deny_fragments: list,
                          bindings: dict):
    """Returns True/False for one already-split segment. A PURE assignment
    segment (e.g. "S=/tmp/x") is not a command: it updates `bindings` (in
    place, visible to later segments, matching real shell order) and counts
    as read-only on its own. Raises ValueError on anything shlex cannot
    tokenise (unterminated quote inside the segment, etc.) -- caller treats
    that as "not readonly".
    """
    tokens = shlex.split(segment, posix=True)
    if not tokens:
        return True  # an empty segment (e.g. from "a;;b") is a no-op
    pairs = _pure_assignment_tokens(tokens)
    if pairs is not None:
        for name, value in pairs:
            if _SIMPLE_ASSIGNMENT_VALUE.match(value):
                bindings[name] = value
            # else: leave unbound -- a later reference to it will correctly
            # fail resolution rather than pick up a half-resolved guess.
        return True
    while tokens and _ENV_ASSIGN.match(tokens[0]):
        tokens = tokens[1:]
    if not tokens:
        return False
    prog, prog_ok = _resolve_or_flag(tokens[0], bindings)
    if not prog_ok:
        return False
    prog_name = _basename(prog)
    if prog not in safe_bins and prog_name not in safe_bins:
        return False
    rest = tokens[1:]
    if prog_name == "sed" and _sed_has_inplace(rest):
        return False
    if prog_name == "find" and _find_has_danger(rest):
        return False
    for tok in rest:
        resolved, ok = _resolve_or_flag(tok, bindings)
        if not ok:
            return False
        for frag in deny_fragments:
            if frag and _matches_deny_fragment(resolved, frag):
                return False
    return True


def is_readonly_command(cmd: str, safe_bins: set, deny_fragments: list) -> bool:
    if not cmd or not cmd.strip():
        return False
    segments, forbidden = _split_top_level(cmd)
    if forbidden or segments is None:
        return False
    if not segments:
        return False
    bindings: dict = {}
    try:
        for seg in segments:
            if not seg.strip():
                continue
            if not _segment_is_readonly(seg, safe_bins, deny_fragments, bindings):
                return False
        return True
    except ValueError:
        return False


def load_profile(path: str = PROFILE_PATH_DEFAULT):
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def decide(tool_name: str, tool_input: dict, profile_path: str = PROFILE_PATH_DEFAULT):
    """Returns an "allow" reason string, or None (do not intervene)."""
    if tool_name != "Bash":
        return None
    cmd = str(tool_input.get("command") or "")
    if not cmd.strip():
        return None
    try:
        profile = load_profile(profile_path)
    except Exception:
        return None  # missing/unreadable profile: never auto-allow
    safe_bins = read_only_binaries_from_profile(profile)
    deny_fragments = deny_fragments_from_profile(profile)
    if not safe_bins or not deny_fragments:
        return None  # empty derived lists look like a broken profile read
    if is_readonly_command(cmd, safe_bins, deny_fragments):
        return (
            "OLVASO PARANCS KAPU: automatikusan engedve. Minden tag a "
            "profil sajat olvaso-listajan all, nincs atiranyitas, "
            "behelyettesites vagy helyben-iras, minden valtozo-hivatkozas "
            "feloldva a blokk sajat NEV=ertek hozzarendeleseibol, es a "
            "feloldott szoveg egyik argumentumban sem tartalmaz tiltott "
            "utvonal-toredeket."
        )
    return None


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0
    tool = str(payload.get("tool_name") or "")
    tool_input = payload.get("tool_input") or {}
    if not isinstance(tool_input, dict):
        return 0
    reason = decide(tool, tool_input)
    if reason is None:
        return 0
    sys.stdout.write(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "permissionDecisionReason": reason,
        }
    }, ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        # Any unexpected failure must degrade to "do not intervene", never
        # to a block and never to a silent allow.
        sys.exit(0)
