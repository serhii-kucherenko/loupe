#!/usr/bin/env python3
"""Fails on a colour, font or radius written anywhere but the theme.

A host app can now hand Loupe its own tokens. That promise is only as good as
the weakest call site: one hardcoded orange, one `.font(.body)`, one
`cornerRadius: 12`, and the overlay is back to looking like a visitor in
somebody else's product - in exactly one control, which is worse than all of
them, because it reads as a bug rather than as a theme.

Nothing but reading the code finds that. It looks right on Loupe's own demo,
where the literal and the token happen to agree, and only goes wrong inside the
host app nobody testing Loupe is running.

    python3 scripts/check-theme-literals.py           # check
    python3 scripts/check-theme-literals.py --list    # what it finds today

`Sources/LoupeUI/LoupeTheme.swift` is the one file allowed to hold these. That
is the whole design: everything visible reads them by name.

Adding an exception: put it in `scripts/theme-literals.allow` with a reason.
The reason is the point - the file is the argument, not the suppression.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
ALLOW = ROOT / "scripts" / "theme-literals.allow"
THEME = "Sources/LoupeUI/LoupeTheme.swift"

# `Color.clear` is not a colour choice, it is "draw nothing" - a measurement
# probe or a hit-test surface. It cannot follow a host's palette because it has
# no appearance to follow.
RULES = [
    ("colour", re.compile(r"\bColor\s*\(|\bColor\.(?!clear\b)[a-z]|"
                          r"\bUIColor\s*\(|\bNSColor\s*\(|#colorLiteral")),
    ("font", re.compile(r"\bFont\.[a-zA-Z]|\.font\(\s*\.[a-zA-Z]")),
    ("radius", re.compile(r"cornerRadius:\s*-?[0-9]")),
]


def findings():
    """(file, line number, kind, the source line) for everything worth arguing about."""
    found = []
    for source in ("Sources", "Examples/LoupeDemo/Sources"):
        for path in sorted((ROOT / source).rglob("*.swift")):
            rel = path.relative_to(ROOT).as_posix()
            if rel == THEME:
                continue
            # The demo app is a host, not part of Loupe. A host is *supposed* to
            # have its own colours - that is the thing being demonstrated - so
            # only the SDK is held to this.
            if rel.startswith("Examples/"):
                continue
            for n, line in enumerate(path.read_text().split("\n"), 1):
                code = line.split("//")[0]
                for kind, pattern in RULES:
                    if pattern.search(code):
                        found.append((rel, n, kind, line.strip()))
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
        print(f"theme literals: {len(every)} known, none new")
        return 0

    print("A colour, font or radius written outside the theme:\n")
    for rel, n, kind, text in new:
        print(f"  {rel}:{n}")
        print(f"    {kind}: {text}\n")
    print("Use a token: LoupeTheme.Colors.*, LoupeTheme.Typography.*,")
    print("LoupeTheme.Radius.*. A value that has no token yet gets one, in")
    print("LoupeTheme.swift and DESIGN.md, in this same change.\n")
    print("If the literal is genuinely right, add it to")
    print("scripts/theme-literals.allow with a reason:")
    print("  <path>\\t<the source line>\\t<why this one is fine>")
    return 1


if __name__ == "__main__":
    sys.exit(main())
