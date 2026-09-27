#!/usr/bin/env python3
"""SessionStart hook: print the fleet's own measuring tools, generated, not hand-kept.

WHY THIS EXISTS, measured 2026-09-01 22:01. Asked whether the commerce part runs on
the production machine, I sent the owner a `docker ps` to run. The answer was already
available to me: `scripts/infra-allapot.sh` prints the live state of BOTH Coolify
machines, and I had written that script myself at 14:51 the same day, after making the
same mistake once. His words: "Most ez komoly??? Egyreszt hozzafersz mindket gepen a
coolifyhoz, masreszt veled csinaltam ma delutan az egesz commerce reszt."

The failure was never missing data or a missing tool. It was that the tool was not in
front of me in the second the question arrived: a container restart at 21:41 had taken
the live session, and a tool nobody remembers is the same as a tool that does not exist.

WHY IT IS GENERATED AND NOT A LIST. A hand-written index rots silently: a script gets
renamed and the index still names the old one, which is worse than no index, because it
reads as current. Here a script declares itself with a single line,

    # ANSWERS: <the question this command answers, in one line>

and this hook finds it. Nothing to keep in sync: if the file is gone the line is gone
with it, and a new tool appears in every future session the moment it declares one.

Read-only: it lists, it never runs any of the tools it names.
"""

import os
import re
import sys

INSTALL_DIR = os.environ.get("CLAUDE_PROJECT_DIR", "/home/marveen/marveen")
SCRIPTS = os.path.join(INSTALL_DIR, "scripts")
MARKER = re.compile(r"^#\s*ANSWERS:\s*(.+?)\s*$")
# A declaration lives in the file header, next to what it describes. Scanning the whole
# file would also match the word inside a heredoc or a comment about this very hook.
HEADER_LINES = 40


def declarations():
    found = []
    for entry in sorted(os.listdir(SCRIPTS)):
        path = os.path.join(SCRIPTS, entry)
        if not os.path.isfile(path):
            continue
        if not (entry.endswith(".sh") or entry.endswith(".py")):
            continue
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                for _ in range(HEADER_LINES):
                    line = fh.readline()
                    if not line:
                        break
                    m = MARKER.match(line)
                    if m:
                        found.append((entry, m.group(1)))
                        break
        except OSError:
            continue
    return found


def main():
    found = declarations()
    if not found:
        return 0
    out = [
        "AMIT MAGAD LE TUDSZ MERNI (a flotta sajat eszkozei, ez a lista generalt).",
        "Mielott a gazdanak parancsot adnal ki futtatasra, nezd meg, hogy nem all-e itt.",
        "",
    ]
    for name, question in found:
        runner = "python3" if name.endswith(".py") else "bash"
        out.append("  %s %s/scripts/%s" % (runner, INSTALL_DIR, name))
        out.append("      %s" % question)
    out.append("")
    out.append(
        "Ha egy uj eszkozt irsz, tedd a fejlecebe egy '# ANSWERS: ...' sort, "
        "es a kovetkezo sessionben mar itt lesz."
    )
    sys.stdout.write("\n".join(out) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
