#!/usr/bin/env python3
"""Fails on a new way for something to fail without saying so.

Six bugs in one evening had one shape: an operation that could fail, a result
nobody was forced to read, and a product that carried on looking fine. A refused
Keychain write. A discarded `session.start()`. A `try?` that turned a dropped
request into "the project was deleted". And a discarded `SecRandomCopyBytes`,
which left sign-in *working* while quietly making the PKCE verifier a constant.

That last one is why this exists rather than another sweep. Every other bug here
was findable by using the product. A failure that leaves the system working has
no symptom at all, so nothing but reading the code will ever find it - and a
sweep finds today's six while the seventh arrives next week.

`try?` and `@discardableResult` are both ergonomic features: they exist to let
you skip a decision, so they collect exactly where somebody did not want to make
one. Neither is wrong. Both have to be argued for once, here, in writing.

    python3 scripts/check-quiet-failures.py           # check
    python3 scripts/check-quiet-failures.py --list    # what it finds today

Adding one: put it in `scripts/quiet-failures.allow` with a reason. The reason
is the point - the file is the argument, not the suppression.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
ALLOW = ROOT / "scripts" / "quiet-failures.allow"


def findings():
    """(file, line number, kind, the source line) for everything worth arguing about."""
    found = []
    for path in sorted((ROOT / "Sources").rglob("*.swift")):
        rel = path.relative_to(ROOT).as_posix()
        lines = path.read_text().split("\n")
        for n, line in enumerate(lines, 1):
            code = line.split("//")[0]
            if "try?" in code:
                found.append((rel, n, "try?", line.strip()))
            # A `@discardableResult` on something returning `Bool` is the exact
            # shape of "this can fail and you need not notice" - it is how a
            # refused Keychain write and a refused delete both went unread.
            if "@discardableResult" in code:
                for ahead in lines[n:n + 6]:
                    if "func " in ahead and re.search(r"->\s*Bool\b", ahead):
                        found.append((rel, n, "@discardableResult -> Bool",
                                      ahead.strip()))
                        break
    return found


def allowed():
    """Every argued-for case, keyed by file and source line rather than by number.

    By text, so moving code around does not silently re-allow something, and
    editing the line does not either.
    """
    if not ALLOW.exists():
        return set()
    keys = set()
    for raw in ALLOW.read_text().split("\n"):
        line = raw.split("#")[0].strip()
        if not line:
            continue
        parts = line.split("\t")
        if len(parts) >= 2:
            keys.add((parts[0].strip(), parts[1].strip()))
    return keys


def main():
    every = findings()
    if "--list" in sys.argv:
        for rel, n, kind, text in every:
            print(f"{rel}:{n}\t{kind}\t{text}")
        return 0

    known = allowed()
    new = [f for f in every if (f[0], f[3]) not in known]
    if not new:
        print(f"quiet failures: {len(every)} known, none new")
        return 0

    print("A new way for something to fail without saying so:\n")
    for rel, n, kind, text in new:
        print(f"  {rel}:{n}")
        print(f"    {kind}: {text}\n")
    print("If it is right, add it to scripts/quiet-failures.allow with a reason:")
    print("  <path>\\t<the source line>\\t<why this one is fine>\n")
    print("If it is not, make the failure reachable - throw it, return it, or")
    print("assert on it. Six bugs in one evening came from this shape.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
