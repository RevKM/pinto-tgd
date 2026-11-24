"""Pinto's changelog, CHANGELOG.md: every release's changes, newest first, each under a
heading "## <version>". The newest heading is the next release's version (tools/release.py),
and "## <version> (important)" marks a fix everyone needs: older copies then ask for the
update at every login. The release build puts a release's changes in the README's
"What's new" and on its release page, and the CurseForge upload sends them as the file's
changelog.

  python tools/changelog.py [<version>]    prints that version's changes (default: newest)
"""
import os
import re
import sys

PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "CHANGELOG.md")
HEADING = re.compile(r"^## +(\S+)(.*)$")


def headings(text):
    """[(version, the rest of its heading)] in the file's order, newest first."""
    return [(m.group(1), m.group(2).strip()) for m in map(HEADING.match, text.splitlines()) if m]


def important(text, version):
    """Whether the version's heading marks it as important."""
    return any(v == version and "important" in rest.lower() for v, rest in headings(text))


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
