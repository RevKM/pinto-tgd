"""Pinto's changelog, CHANGELOG.md: every release's changes, newest first, each under a
heading "## <version>". The release build puts a release's changes in the README's
"What's new" and on its release page, and the CurseForge upload sends them as the file's
changelog.

  python tools/changelog.py [<version>]    prints that version's changes (default: newest)
"""
import os
import re
import sys

PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "CHANGELOG.md")
HEADING = re.compile(r"^## +(\S+)")


def sections(text):
    """[(version, changes)] in the file's order, newest first."""
    found, current = [], None
    for line in text.splitlines():
        m = HEADING.match(line)
        if m:
            current = (m.group(1), [])
            found.append(current)
        elif current:
            current[1].append(line)
    return [(version, "\n".join(lines).strip()) for version, lines in found]


def section(text, version):
    """One version's changes, or None if it has none."""
    for v, changes in sections(text):
        if v == version:
            return changes or None
    return None


def main(argv):
    with open(PATH, encoding="utf-8") as f:
        text = f.read()
    found = sections(text)
    if not found:
        sys.exit("CHANGELOG.md has no '## <version>' sections")
    version = argv[0] if argv else found[0][0]
    changes = section(text, version)
    if not changes:
        sys.exit("CHANGELOG.md has no changes for %s" % version)
    print(changes)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
