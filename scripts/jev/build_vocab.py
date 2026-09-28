#!/usr/bin/env python3
# ANSWERS: Mely szavak koznapiak a sajat szovegeinkben (kisbetuvel is elofordulnak), hogy a kitakaro a mondat eleji nagybetus szot meg tudja kulonboztetni a nevtol?
"""Builds store/jev-common-words.txt for redact.py.

The problem it solves: Hungarian capitalises only the first word of a
sentence and proper nouns, so "Bodnár szerint..." and "Holnap szerint..."
look the same. A word that our own texts also use in lower case, often and
at least half as often as capitalised, is an ordinary word. Anything else
that opens a sentence with a capital is treated as a proper noun.

Source: the dashboard database (memories, daily logs, card comments,
agent messages), read only. Listed names and tokens next to an "@" are
never admitted, so an email local part cannot turn a name into a word.
The file holds single common words only, and lives in store/ (gitignored)
because it is derived from internal text.
"""
import collections
import os
import re
import sqlite3
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
import redact  # noqa: E402

DB = "/home/marveen/marveen/store/claudeclaw.db"
OUT = redact.COMMON_WORDS_PATH
SOURCES = [("memories", "content"), ("daily_logs", "content"),
           ("kanban_comments", "content"), ("agent_messages", "content")]
WORD = re.compile(r"(?<![\w@.])([^\W\d_]{2,})(?![\w@])")


def main():
    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    lower, cap = collections.Counter(), collections.Counter()
    for table, col in SOURCES:
        for (text,) in con.execute(f'select "{col}" from "{table}"'):
            for m in WORD.finditer(text or ""):
                w = m.group(1)
                f = redact.fold(w)
                if w[0].islower():
                    lower[f] += 1
                elif any(c.islower() for c in w[1:]):
                    cap[f] += 1
    words = sorted(f for f, n in lower.items()
                   if n >= 3 and n * 2 >= cap[f]
                   and not redact._is_name(f) and f not in redact.GIVEN_NAMES)
    tmp = OUT + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write("\n".join(words) + "\n")
    os.replace(tmp, OUT)
    print(f"{len(words)} common words -> {OUT}")


if __name__ == "__main__":
    main()
