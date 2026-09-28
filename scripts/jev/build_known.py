#!/usr/bin/env python3
# ANSWERS: Mely nevek, cimek, cegek allnak a sajat adatbazisunkban, lenyomatkent (a kitakaro A retegehez)? Nevet nem ir ki es nem ment.
"""Builds store/jev-known-entities.json for layer A of redact.py.

Reads the Acropora OS production database through the prod host (read
only, one SELECT), keeps the rows in memory only, and writes keyed
digests. No name, address or email reaches the disk, a log, or stdout:
the output is counts per kind. Same rule as vevo-osszesito.py.

Which container: the one the API actually uses (memory: two postgres
containers answer to the same name; the stale one is our compose sibling).

Usage: python3 build_known.py            (writes the file)
       python3 build_known.py --dry-run  (counts only)
"""
import os
import subprocess
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
import redact  # noqa: E402

HOST = "fleet@162.55.216.28"
KEY = os.path.expanduser("~/.ssh/id_ed25519_acropora_monitor")
CONTAINER = "iwm34jaqp9xmwb72qkrqkwhy"

# kind <TAB> value. Cities and postal codes are left out on purpose: layer B
# handles postal codes, and a town name alone identifies no one.
SQL = r"""
select 'PERSON', trim(coalesce("firstName",'') || ' ' || coalesce("lastName",'')) from "User"
union all select 'PERSON', trim(coalesce("lastName",'') || ' ' || coalesce("firstName",'')) from "User"
union all select 'PERSON', "displayName" from "User"
union all select 'PERSON', "nickname" from "User"
union all select 'EMAIL', "email" from "User"
union all select 'ORG', "displayName" from "Customer"
union all select 'ORG', "companyName" from "Customer"
union all select 'EMAIL', "email" from "Customer"
union all select 'ADDRESS', "name" from "CustomerAddress"
union all select 'ADDRESS', "line1" from "CustomerAddress"
union all select 'ADDRESS', "line2" from "CustomerAddress"
union all select 'ORG', "name" from "Supplier"
union all select 'PERSON', "contactPersonName" from "Supplier"
union all select 'EMAIL', "email" from "Supplier"
union all select 'EMAIL', "contactPersonEmail" from "Supplier"
union all select 'PERSON', "contactPersonName" from "Contract"
union all select 'ORG', "organizationalUnitName" from "Contract"
union all select 'PERSON', "signerName" from "WorksheetVersionSignature"
"""


def fetch():
    cmd = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-i", KEY, HOST,
           "docker", "exec", "-i", CONTAINER, "psql", "-U", "acropora", "-d", "acropora",
           "-At", "-F", "'|'", "-v", "ON_ERROR_STOP=1"]
    r = subprocess.run(cmd, input=SQL.encode(), capture_output=True, timeout=120)
    if r.returncode != 0:
        # stderr can quote the query, never row data; still print only the first line
        sys.stderr.write("FAIL psql: " + r.stderr.decode(errors="replace").splitlines()[0][:200] + "\n")
        sys.exit(1)
    for line in r.stdout.decode("utf-8", "replace").splitlines():
        kind, _, value = line.partition("|")
        yield kind, value


def admit(kind, value):
    toks = redact.entity_tokens(value or "")
    if not toks:
        return False
    if len(toks) == 1:
        # one word masks that word everywhere: only for names of places and
        # organisations, never short, never a preserved term or a common opener
        t = toks[0]
        if kind == "PERSON" or len(t) < 5 or t in redact.PRESERVE or t in redact._OPENERS:
            return False
    if redact.known_key(toks) in redact.PRESERVE:
        return False
    return True


def main():
    rows = list(fetch())
    kept, counts = [], {}
    for kind, value in rows:
        if admit(kind, value):
            kept.append((kind, value))
            counts[kind] = counts.get(kind, 0) + 1
    print(f"rows {len(rows)}, admitted {len(kept)}: " + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())))
    if "--dry-run" not in sys.argv:
        n = redact.write_known_file(kept, redact.KNOWN_ENTITIES_PATH)
        print(f"wrote {n} digests to {redact.KNOWN_ENTITIES_PATH}")


if __name__ == "__main__":
    main()
