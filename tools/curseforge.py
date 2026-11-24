"""Uploads a Pinto release zip to CurseForge.

.github/workflows/curseforge.yml runs this when a GitHub release is published, on the zip
attached to that release: the one tools/build.py release built and signed on the
maintainer's PC. The signing key never comes near it; this only checks the zip and passes
it on.

  python tools/curseforge.py <zip> <tag> [<CHANGELOG.md>]

Before uploading, it checks that the zip is a signed release build of the tag's version,
not a test or beta build. The game version comes from the zip's ## Interface (16001 is
"1.60.1") and is looked up among CurseForge's game versions. The file's changelog is the
version's section of CHANGELOG.md (see tools/changelog.py), and the upload stops if it
has none.

Environment:
  CF_API_TOKEN        a CurseForge API token, from https://authors.curseforge.com/#/settings/api-tokens
  CF_PROJECT_ID       the CurseForge project's id
  CF_GAME_VERSION_ID  optional: the game version's id, to use instead of looking it up
  CF_API              optional: the API's address, https://wow.curseforge.com by default
"""
import json
import os
import re
import secrets
import sys
import urllib.error
import urllib.request
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import changelog  # noqa: E402

ADDON = "PintoTGD"


def fail(msg):
    sys.exit("curseforge: " + msg)


def api():
    return (os.environ.get("CF_API") or "https://wow.curseforge.com").rstrip("/")


def check_zip(path, version):
    """Checks the zip is a signed release build of version; returns its game version name."""
    try:
        z = zipfile.ZipFile(path)
    except (OSError, zipfile.BadZipFile) as e:
        fail("can't open %s: %s" % (path, e))
    toc_name, build_name = "%s/%s.toc" % (ADDON, ADDON), "%s/Core/Build.lua" % ADDON
    with z:
        names = set(z.namelist())
        for need in (toc_name, build_name):
            if need not in names:
                fail("%s has no %s: attach the zip that tools/build.py release made" % (path, need))
        toc = z.read(toc_name).decode("utf-8")
        build = z.read(build_name).decode("utf-8")

    def field(pattern, text, what):
        m = re.search(pattern, text, re.M)
        if not m:
            fail("%s: can't find its %s" % (path, what))
        return m.group(1)

    if (field(r'^\s*test = (\w+),', build, "test flag") != "false"
            or field(r'^\s*testTools = (\w+),', build, "test tools flag") != "false"):
        fail("%s is a test or beta build, not a release" % path)
    if not re.search(r'^\s*stampSig = "[0-9a-f]{128}",', build, re.M):
        fail("%s has no signed release stamp" % path)
    built = field(r'^\s*version = "([^"]+)",', build, "version")
    listed = field(r'^## Version: (\S+)', toc, "## Version")
    if built != version or listed != version:
        fail("%s holds version %s, but the release is %s" % (path, built, version))
    n = int(field(r'^## Interface: (\d+)', toc, "## Interface"))
    return "%d.%d.%d" % (n // 10000, n // 100 % 100, n % 100)


def call(method, path, body=None, content_type=None):
    req = urllib.request.Request(api() + path, data=body, method=method)
    req.add_header("X-Api-Token", os.environ["CF_API_TOKEN"].strip())
    req.add_header("User-Agent", "pinto-release-upload")
    req.add_header("Accept", "application/json")
    if content_type:
        req.add_header("Content-Type", content_type)
    try:
        with urllib.request.urlopen(req, timeout=120) as res:
            return json.loads(res.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        fail("%s %s failed: %d %s" % (method, path, e.code, e.read().decode("utf-8", "replace")[:500]))
    except urllib.error.URLError as e:
        fail("%s %s failed: %s" % (method, path, e.reason))
    except ValueError:
        fail("%s %s answered with something that isn't JSON" % (method, path))


def game_version_id(name):
    fixed = os.environ.get("CF_GAME_VERSION_ID", "").strip()
    if fixed:
        if not fixed.isdigit():
            fail("CF_GAME_VERSION_ID must be a number, not %r" % fixed)
        return int(fixed)
    versions = call("GET", "/api/game/versions")
    found = [v for v in versions if isinstance(v, dict) and v.get("name") == name]
    if len(found) != 1:
        which = ", ".join("id %s (type %s)" % (v.get("id"), v.get("gameVersionTypeID")) for v in found)
        fail("CurseForge has %d game versions named %s%s. Set the CF_GAME_VERSION_ID variable "
             "to the right one's id." % (len(found), name, ": " + which if which else ""))
    return int(found[0]["id"])


def multipart(metadata, file_name, file_bytes):
    """The two fields CurseForge wants, metadata and file, as multipart/form-data."""
    boundary = "pinto-" + secrets.token_hex(16)
    body = b"".join([
        ('--%s\r\nContent-Disposition: form-data; name="metadata"\r\n\r\n' % boundary).encode("ascii"),
        json.dumps(metadata).encode("utf-8"),
        ('\r\n--%s\r\nContent-Disposition: form-data; name="file"; filename="%s"\r\n'
         'Content-Type: application/zip\r\n\r\n' % (boundary, file_name)).encode("ascii"),
        file_bytes,
        ("\r\n--%s--\r\n" % boundary).encode("ascii"),
    ])
    return body, "multipart/form-data; boundary=" + boundary


def main(argv):
    if len(argv) not in (2, 3):
        print(__doc__)
        return 2
    path, tag = argv[0], argv[1]
    version = tag[1:] if tag.startswith("v") else tag
    for var in ("CF_API_TOKEN", "CF_PROJECT_ID"):
        if not os.environ.get(var, "").strip():
            fail("%s isn't set: see the top of tools/curseforge.py" % var)
    project = os.environ["CF_PROJECT_ID"].strip()
    if not project.isdigit():
        fail("CF_PROJECT_ID must be the project's number, not %r" % project)
    game = check_zip(path, version)
    changes = None
    if len(argv) == 3:
        with open(argv[2], encoding="utf-8") as f:
            changes = changelog.section(f.read(), version)
        if not changes:
            fail("%s has no changes for %s: add them under \"## %s\"" % (argv[2], version, version))
    game_id = game_version_id(game)
    metadata = {
        "changelog": changes or "Pinto %s." % version,
        "changelogType": "markdown",
        "displayName": "Pinto %s" % version,
        "gameVersions": [game_id],
        "releaseType": "release",
    }
    with open(path, "rb") as f:
        body, content_type = multipart(metadata, os.path.basename(path), f.read())
    res = call("POST", "/api/projects/%s/upload-file" % project, body, content_type)
    file_id = res.get("id") if isinstance(res, dict) else None
    if file_id is None:
        fail("CurseForge didn't say which file it made: %r" % (res,))
    print("Uploaded %s to CurseForge as file %s, for game version %s (id %d)."
          % (os.path.basename(path), file_id, game, game_id))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
