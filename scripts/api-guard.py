#!/usr/bin/env python3
# ANSWERS: Van-e a Marveen futo kornyezeteben API-szamlazast bekapcsolo beallitas (ANTHROPIC_API_KEY, OPENAI_API_KEY, authMode=api stb.)? Erteket soha nem ir ki.
"""
api-guard.py -- read-only check for configuration that would switch the fleet
from subscription to pay-per-use API billing (Measurement Layer v1, item 13).

Checks, NAMES ONLY (a value is never read into output, never logged):
  * environment of every process this user can read (/proc/<pid>/environ),
  * the install's .env file (keys only),
  * each agent's agent-config.json (authMode, model routed off Anthropic),
  * vault entry ids that follow an API-key naming convention.

Output: one JSON object per finding on stdout:
  {"provider","variable_name","component","detected"}
plus a final summary line. With --warn-only, prints only WARNING lines
(for a heartbeat that must stay silent when all is clean).

Never stops, edits or restarts anything. Exit code is always 0; the verdict
is in the output. Processes of other OS users are unreadable by design and
are reported as such, not as clean.
"""
import json
import os
import sys

ROOT = os.environ.get("MARVEEN_ROOT", "/home/marveen/marveen")

WATCHED = {
    "ANTHROPIC_API_KEY": "anthropic",
    "ANTHROPIC_AUTH_TOKEN": "anthropic-compatible",
    "ANTHROPIC_BASE_URL": "anthropic-compatible",
    "CLAUDE_CODE_USE_BEDROCK": "aws-bedrock",
    "CLAUDE_CODE_USE_VERTEX": "google-vertex",
    "OPENAI_API_KEY": "openai",
    "GEMINI_API_KEY": "google",
    "OPENROUTER_API_KEY": "openrouter",
    "DEEPSEEK_API_KEY": "deepseek",
}
# Vault ids that agent-process.ts would inject as API credentials.
VAULT_PATTERNS = ("-api-key", "openrouter-fleet-key", "DEEPSEEK_API_KEY")


def proc_findings():
    out, unreadable = [], 0
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                cmd = f.read().split(b"\0")
            with open(f"/proc/{pid}/environ", "rb") as f:
                names = {e.split(b"=", 1)[0].decode("utf-8", "replace") for e in f.read().split(b"\0") if e}
        except PermissionError:
            unreadable += 1
            continue
        except OSError:
            continue
        exe = os.path.basename(cmd[0].decode("utf-8", "replace")) if cmd and cmd[0] else "?"
        if exe not in ("claude", "node", "bun", "python3", "bash"):
            continue
        for var, prov in WATCHED.items():
            if var in names:
                out.append({"provider": prov, "variable_name": var,
                            "component": f"process {pid} ({exe})", "detected": True})
    return out, unreadable


def env_file_findings():
    out = []
    p = os.path.join(ROOT, ".env")
    try:
        with open(p) as f:
            for line in f:
                key = line.split("=", 1)[0].strip()
                if key in WATCHED and "=" in line and line.split("=", 1)[1].strip().strip('"'):
                    out.append({"provider": WATCHED[key], "variable_name": key,
                                "component": ".env", "detected": True})
    except OSError:
        pass
    return out


def agent_findings():
    out = []
    agents_dir = os.path.join(ROOT, "agents")
    try:
        names = sorted(os.listdir(agents_dir))
    except OSError:
        return out
    for n in names:
        p = os.path.join(agents_dir, n, "agent-config.json")
        try:
            with open(p) as f:
                cfg = json.load(f)
        except (OSError, ValueError):
            continue
        if cfg.get("authMode") == "api":
            out.append({"provider": "anthropic", "variable_name": "authMode=api",
                        "component": f"agent {n}", "detected": True})
        model = cfg.get("model")
        if isinstance(model, str) and model and not model.startswith("claude-"):
            out.append({"provider": "non-anthropic model route", "variable_name": f"model={model}",
                        "component": f"agent {n}", "detected": True})
    return out


def vault_findings():
    out = []
    p = os.path.join(ROOT, "store", "vault.json")
    try:
        with open(p) as f:
            v = json.load(f)
    except (OSError, ValueError):
        return out
    ids = []
    if isinstance(v, dict):
        entries = v.get("secrets", v)
        ids = list(entries.keys()) if isinstance(entries, dict) else [e.get("id") for e in entries if isinstance(e, dict)]
    for i in ids:
        if isinstance(i, str) and any(pat in i for pat in VAULT_PATTERNS):
            out.append({"provider": "vault", "variable_name": i, "component": "store/vault.json", "detected": True})
    return out


def main():
    warn_only = "--warn-only" in sys.argv
    procs, unreadable = proc_findings()
    findings = procs + env_file_findings() + agent_findings() + vault_findings()
    for fnd in findings:
        if warn_only:
            print(f"WARNING api-billing config: {fnd['variable_name']} in {fnd['component']} ({fnd['provider']})")
        else:
            print(json.dumps(fnd, ensure_ascii=False))
    if not warn_only:
        print(json.dumps({"summary": True, "detected": len(findings) > 0, "findings": len(findings),
                          "unreadable_processes": unreadable,
                          "note": "processes of other OS users are not visible to this check"}))


if __name__ == "__main__":
    main()
