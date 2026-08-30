#!/usr/bin/env python3
"""Fails on an API that would put a person into a bug report.

A bundle is written to be pasted: into a Linear issue, into a pull request, into a
public repository. That is the whole point of it. It is also why what goes in is a
promise rather than a preference - the moment a bundle carries something somebody
would not want in a ticket, it stops being safe to share, and a tool nobody can share
the output of is not worth having.

Loupe says which *model* the note came from, on what OS, at what screen size. It
never says whose device it was.

The reason this is a lint and not a code review note: every API below is one autocomplete
away from the ones Loupe legitimately uses, reads perfectly innocent at the call site,
and produces a bundle that looks completely normal. Nobody reviewing a diff notices
`UIDevice.current.name` where `UIDevice.current.model` was meant. The person whose
iPad is called "Serhii's iPad" notices, once it is already in a public issue.

    python3 scripts/check-nothing-identifying.py           # check
    python3 scripts/check-nothing-identifying.py --list    # what it finds today

Adding an exception: put it in `scripts/nothing-identifying.allow` with a reason. The
reason is the point - the file is the argument, not the suppression.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
ALLOW = ROOT / "scripts" / "nothing-identifying.allow"

# Each entry is (what it would leak, the pattern). Written as words a reader can
# check rather than as one clever regex.
RULES = [
    ("the name somebody gave their device",
     re.compile(r"UIDevice\s*\.\s*current\s*\.\s*name|WKInterfaceDevice\s*\.\s*current\(\)\s*\.\s*name"
                r"|Host\s*\.\s*current\(\)\s*\.\s*localizedName|SCDynamicStoreCopyComputerName"
                r"|NSFullUserName|NSUserName\s*\(")),
    ("an identifier that follows a person between sessions",
     re.compile(r"identifierForVendor|advertisingIdentifier|ASIdentifierManager"
                r"|IOPlatformUUID|IOPlatformSerialNumber|\bgetuid\s*\(")),
    ("who is signed in",
     re.compile(r"\bNSHomeDirectory\s*\(|homeDirectoryForCurrentUser"
                r"|CNContactStore|ASAuthorizationAppleID")),
    ("a fingerprint of the browser or the person",
     re.compile(r"navigator\s*\.\s*userAgent|navigator\s*\.\s*languages?\b"
                r"|navigator\s*\.\s*hardwareConcurrency|navigator\s*\.\s*deviceMemory"
                r"|userAgentData|resolvedOptions\(\)\s*\.\s*timeZone")),
]

# Where a bundle's contents are decided. The demo and the tests are not shipped into
# anybody's app, and a test that asserts a forbidden word does not appear must be
# allowed to name it.
ROOTS = ["Sources", "web/src"]


def findings():
    """(file, line number, what it would leak, the source line)."""
    found = []
    for source in ROOTS:
        base = ROOT / source
        if not base.exists():
            continue
        for path in sorted(base.rglob("*")):
            if path.suffix not in {".swift", ".ts"} or not path.is_file():
                continue
            rel = path.relative_to(ROOT).as_posix()
            for n, line in enumerate(path.read_text().split("\n"), 1):
                # Comments are where this rule is *explained*, so they are not hits.
                code = re.split(r"//|/\*", line)[0]
                for leaks, pattern in RULES:
                    if pattern.search(code):
                        found.append((rel, n, leaks, line.strip()))
    return found


def allowed():
    """Every argued-for case, keyed by file and source line rather than by number."""
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
        for rel, n, leaks, text in every:
            print(f"{rel}:{n}\t{leaks}\t{text}")
        return 0

    known = allowed()
    new = [f for f in every if (f[0], f[3]) not in known]
    if not new:
        print(f"nothing identifying: {len(every)} known, none new")
        return 0

    print("Something that would put a person into a bug report:\n")
    for rel, n, leaks, text in new:
        print(f"  {rel}:{n}")
        print(f"    {leaks}: {text}\n")
    print("A bundle is written to be pasted into a ticket, a pull request, or a")
    print("public repository. Loupe says which model and which OS; it never says")
    print("whose device it was. Use the model rather than the name, and leave a")
    print("field absent rather than filling it with a person.\n")
    print("If this one is genuinely fine, add it to")
    print("scripts/nothing-identifying.allow with a reason:")
    print("  <path>\\t<the source line>\\t<why this one is fine>")
    return 1


if __name__ == "__main__":
    sys.exit(main())
