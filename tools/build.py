"""Builds Pinto.

  python tools/build.py dev
      Writes the quest pack and a test-build Build.lua into src/, signed with the test
      key (keys/test.key, made on first use), so the addon runs straight from src/.

  python tools/build.py test [--go-live YYYY-MM-DD] [--wake-up YYYY-MM-DD]
      A test build in dist/, with its own dates and the test key. While a test runs,
      tools/test.json holds its dates ({"goLive": ..., "wakeUp": ...}), so every rebuild
      keeps them; without that file, go-live is today. --wake-up sets the day Pinto wakes
      up at 03:00, instead of 7 days after go-live. Test builds use their own message
      prefix and keep their data apart.

  python tools/build.py beta [--go-live YYYY-MM-DD] [--wake-up YYYY-MM-DD]
      A test build without the test tools, to hand to a few guildies: no /pinto test, test
      controls or debug panel. It has the test build's dates, key, message prefix and
      saved data, so it syncs with test builds. Also zips it as dist/PintoTGD-beta.zip.

  python tools/build.py probe
      The probe addon (milestone 0) in dist/PintoProbe. See tools/probe/README.md.

  python tools/build.py release [--version X.Y.Z] [--go-live YYYY-MM-DD] [--wake-up YYYY-MM-DD]
                                [--important]
      A release build in dist/, signed with keys/release.key, and zipped as
      dist/PintoTGD-<version>.zip for the GitHub release. Defaults come from
      tools/release.json. Make the release key once with:
          python tools/ed25519.py keygen keys/release.key
      and keep a backup: addons only trust what this key has signed.
      CHANGELOG.md must have the version's changes, under "## <version>": the build puts
      them in the README's "What's new" block and on the release page.

dist/PintoTGD gets the .toc, every file the .toc lists and Media/. dist/README.md is the
text for the release page: what's new, how to install it and what Pinto is.
"""
import datetime
import json
import os
import re
import shutil
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import changelog  # noqa: E402
import ed25519  # noqa: E402

SRC = os.path.join(ROOT, "src", "PintoTGD")
DIST = os.path.join(ROOT, "dist")
KEYS = os.path.join(ROOT, "keys")
QUESTS = os.path.join(ROOT, "quests")
RELEASE = os.path.join(ROOT, "tools", "release.json")
TEST = os.path.join(ROOT, "tools", "test.json")
CHANGELOG = os.path.join(ROOT, "CHANGELOG.md")
README_MAIN = os.path.join(ROOT, "README.md")

PACK_FORMAT = 1


# The value tree inside a quest pack (read by Quests/Pack.lua) ---------------------------

def varint(n):
    if n < 0:
        raise ValueError("varint must be non-negative")
    out = bytearray()
    while True:
        b = n % 128
        n //= 128
        out.append(b + 128 if n else b)
        if not n:
            return bytes(out)


def string(s, limit):
    b = s.encode("utf-8")
    if len(b) > limit:
        raise ValueError("string too long: %r" % s)
    return varint(len(b)) + b


def tree(v):
    if v is None or v is False:
        return b"\x00"
    if v is True:
        return b"\x01"
    if isinstance(v, int):
        return b"\x02" + varint(v) if v >= 0 else b"\x03" + varint(-v)
    if isinstance(v, str):
        return b"\x04" + string(v, 4096)
    if isinstance(v, list):
        return b"\x05" + varint(len(v)) + b"".join(tree(x) for x in v)
    if isinstance(v, dict):
        keys = sorted(v.keys(), key=lambda k: k.encode("utf-8"))
        return b"\x06" + varint(len(keys)) + b"".join(string(k, 64) + tree(v[k]) for k in keys)
    raise TypeError("quest data can only hold true, false, whole numbers, text, lists and maps: %r" % (v,))


def load_templates():
    templates, bosses, boss_ids = [], [], []
    seen = set()
    for name in ("calibration.json", "set1.json", "set2.json"):
        with open(os.path.join(QUESTS, name), encoding="utf-8") as f:
            doc = json.load(f)
        for t in doc["templates"]:
            t = dict(t)
            t["set"] = doc["set"]
            if t["id"] in seen:
                raise ValueError("quest id %d is used twice" % t["id"])
            seen.add(t["id"])
            if t["worth"] not in (1, 2, 3):
                raise ValueError("quest %d: worth must be 1 to 3" % t["id"])
            if not t.get("text"):
                raise ValueError("quest %d has no text" % t["id"])
            templates.append(t)
        bosses += doc.get("finalBosses", [])
        for i in doc.get("finalBossIds", []):
            if not isinstance(i, int) or isinstance(i, bool) or i <= 0:
                raise ValueError("finalBossIds holds encounter ids, not %r" % (i,))
            boss_ids.append(i)
    return templates, bosses, boss_ids


def build_pack(num):
    templates, bosses, boss_ids = load_templates()
    root = {"templates": templates, "finalBosses": bosses}
    if boss_ids:
        root["finalBossIds"] = boss_ids
    data = b"PintoPack" + num.to_bytes(2, "big") + bytes([PACK_FORMAT]) + tree(root)
    if len(data) > 65535:
        raise ValueError("quest pack too big: %d bytes" % len(data))
    return data


def stamp_body(cfg):
    return (b"PintoStamp" + string(cfg["version"], 16) + bytes([cfg["dataVersion"], cfg["protocolVersion"]])
            + cfg["questPack"].to_bytes(2, "big") + (b"\x01" if cfg["important"] else b"\x00"))


# Keys ---------------------------------------------------------------------------------

def load_key(name, create):
    path = os.path.join(KEYS, name)
    if not os.path.exists(path):
        if not create:
            sys.exit("No %s. Make it once with:\n  python tools/ed25519.py keygen keys/%s\n"
                     "and keep a backup: addons only trust what this key has signed." % (path, name))
        os.makedirs(KEYS, exist_ok=True)
        seed, _ = ed25519.keygen()
        with open(path, "w") as f:
            f.write(seed.hex() + "\n")
        print("made the test key", path)
    with open(path) as f:
        seed = bytes.fromhex(f.read().strip())
    return seed, ed25519.publickey(seed)


# Lua output -----------------------------------------------------------------------------

def lua_bytes(b):
    tokens = []
    for c in b:
        if 32 <= c < 127 and c not in (34, 92):
            tokens.append(chr(c))
        else:
            tokens.append("\\%03d" % c)
    # keep lines readable in an editor, never splitting an escape
    lines, line = [], ""
    for tok in tokens:
        if len(line) + len(tok) > 100:
            lines.append(line)
            line = ""
        line += tok
    lines.append(line)
    return '"' + '"\n  .. "'.join(lines) + '"'


def write_packdata(path, num, data, sig):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("-- The quest pack this build carries, written by tools/build.py from quests/*.json.\n")
        f.write("-- Signed data, not code: see Quests/Pack.lua for the format.\n")
        f.write("local ADDON, ns = ...\n\n")
        f.write("ns.QuestPackData = {\n")
        f.write("  num = %d,\n" % num)
        f.write("  sig = \"%s\",\n" % sig.hex())
        f.write("  data = %s,\n" % lua_bytes(data))
        f.write("}\n")


def write_build(path, cfg, test, tools, public, stamp_sig):
    lines = [
        "-- Build constants, written by tools/build.py.",
        "local ADDON, ns = ...",
        "",
        "ns.Build = {",
        "  version = \"%s\"," % cfg["version"],
        "  dataVersion = %d," % cfg["dataVersion"],
        "  protocolVersion = %d," % cfg["protocolVersion"],
        "  formulaVersion = %d," % cfg["formulaVersion"],
        "  questPack = %d," % cfg["questPack"],
        "  -- The go-live date, in server time. Nothing is recorded before it.",
        "  goLive = \"%s\"," % cfg["goLive"],
    ]
    if cfg.get("wakeUp"):
        lines += [
            "  -- Pinto wakes up at 03:00 server time on this day, not 7 days after go-live.",
            "  wakeUp = \"%s\"," % cfg["wakeUp"],
        ]
    lines += [
        "  -- Test builds carry their own date and keep their data apart from release data.",
        "  test = %s," % ("true" if test else "false"),
        "  -- The test tools: /pinto test, the test controls and the debug panel. Beta and",
        "  -- release builds don't have them.",
        "  testTools = %s," % ("true" if tools else "false"),
        "  important = %s," % ("true" if cfg["important"] else "false"),
        "  -- Ed25519 public key (hex) that release stamps and quest packs must be signed with.",
        "  publicKey = \"%s\"," % public.hex(),
    ]
    if stamp_sig:
        lines.append("  stampSig = \"%s\"," % stamp_sig.hex())
    lines.append("  releaseUrl = \"%s\"," % cfg["releaseUrl"])
    lines.append("}")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")


def toc_files():
    files = []
    with open(os.path.join(SRC, "PintoTGD.toc"), encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                files.append(line.replace("\\", "/"))
    return files


README = """{whats_new}## Install

1. Download `PintoTGD-{version}.zip` below.
2. Unzip it into `World of Warcraft/_forever_/Interface/AddOns/`, so that you get
   `AddOns/PintoTGD/PintoTGD.toc`.
3. Log in with a character in The Girthy Dragons. Click Pinto's head on the minimap, or type `/pinto`.

There's nothing to set up. Update by replacing the folder; your saved data updates itself.

## Pinto, the Girthy Dragon

A WoW: Forever addon for The Girthy Dragons. It shows the guild's social health as a dragon
on a gold hoard: Pinto gets fatter as guildies play together, and each character gets 4 meta
quests a week that feed him.

- Everything stays inside the game: the guild's addons share data among themselves.
- Pinto only shows guild-level health. There are no leaderboards or personal scores.
- A second WoW license: type `/pinto link` on one and `/pinto link CODE` on the other.
- The code is readable as-is. Saved data is stored compactly encoded.

Version {version}.{all_changes}
"""


# The changelog ------------------------------------------------------------------------

def changes_of(version, required):
    """The version's changes from CHANGELOG.md; a release can't be built without them."""
    with open(CHANGELOG, encoding="utf-8") as f:
        changes = changelog.section(f.read(), version)
    if not changes and required:
        sys.exit("CHANGELOG.md has no changes for %s yet: add them under \"## %s\", newest first."
                 % (version, version))
    return changes


def whats_new(version, changes):
    return ("## What's new in %s\n\n%s\n\nEvery release's changes are in [CHANGELOG.md](CHANGELOG.md).\n"
            % (version, changes))


# The README's block between these markers is the newest release's changes.
WHATS_NEW_BLOCK = re.compile(r"(<!-- whats-new[^>]*-->\n).*?(<!-- /whats-new -->)", re.S)


def update_readme(version, changes):
    with open(README_MAIN, encoding="utf-8") as f:
        text = f.read()
    new, n = WHATS_NEW_BLOCK.subn(lambda m: m.group(1) + whats_new(version, changes) + m.group(2), text)
    if n != 1:
        sys.exit("README.md needs one <!-- whats-new --> ... <!-- /whats-new --> block for the newest changes")
    if new != text:
        with open(README_MAIN, "w", encoding="utf-8", newline="\n") as f:
            f.write(new)
    print("README.md: what's new in", version)


def release_text(cfg, changes):
    """dist/README.md: the text for the release page."""
    new = ""
    if changes:
        new = "## What's new in %s\n\n%s\n\n" % (cfg["version"], changes)
    url = cfg.get("releaseUrl", "")
    repo = url.split("/releases")[0] if "/releases" in url else None
    all_changes = (" Every release's changes: [CHANGELOG.md](%s/blob/main/CHANGELOG.md)." % repo) if repo else ""
    return README.format(whats_new=new, version=cfg["version"], all_changes=all_changes)


def copy_dist(cfg, test, tools, public, stamp_sig, pack_num, pack_data, pack_sig, changes=None):
    out = os.path.join(DIST, "PintoTGD")
    if os.path.exists(out):
        shutil.rmtree(out)
    os.makedirs(out)
    shutil.copy2(os.path.join(SRC, "PintoTGD.toc"), out)
    for rel in toc_files():
        src = os.path.join(SRC, rel)
        dst = os.path.join(out, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        if rel == "Core/Build.lua":
            write_build(dst, cfg, test, tools, public, stamp_sig)
        elif rel == "Quests/PackData.lua":
            write_packdata(dst, pack_num, pack_data, pack_sig)
        else:
            shutil.copy2(src, dst)
    media = os.path.join(SRC, "Media")
    if os.path.isdir(media):
        shutil.copytree(media, os.path.join(out, "Media"))
    with open(os.path.join(DIST, "README.md"), "w", encoding="utf-8", newline="\n") as f:
        f.write(release_text(cfg, changes))
    # stamp the version into the .toc copy
    toc = os.path.join(out, "PintoTGD.toc")
    with open(toc, encoding="utf-8") as f:
        text = f.read()
    with open(toc, "w", encoding="utf-8", newline="\n") as f:
        f.write(text.replace("## Version: 0.0.0", "## Version: " + cfg["version"]))
    print("built", out)


def zip_dist(name):
    """Zips dist/PintoTGD as dist/<name>, the folder at the top, to unpack into AddOns/."""
    path = os.path.join(DIST, name)
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for folder, dirs, files in os.walk(os.path.join(DIST, "PintoTGD")):
            dirs.sort()
            for f in sorted(files):
                full = os.path.join(folder, f)
                z.write(full, os.path.relpath(full, DIST).replace(os.sep, "/"))
    print("zipped", path)


def build_probe():
    out = os.path.join(DIST, "PintoProbe")
    if os.path.exists(out):
        shutil.rmtree(out)
    shutil.copytree(os.path.join(ROOT, "tools", "probe", "PintoProbe"), out)
    shutil.copy2(os.path.join(SRC, "Sync", "Crypto.lua"), os.path.join(out, "Crypto.lua"))
    for name in ("Circle.tga", "Tri.tga"):
        shutil.copy2(os.path.join(SRC, "Media", name), os.path.join(out, name))
    print("built", out)


def main(argv):
    if argv and argv[0] == "probe":
        build_probe()
        return 0
    if not argv or argv[0] not in ("dev", "test", "beta", "release"):
        print(__doc__)
        return 2
    mode = argv[0]
    with open(RELEASE, encoding="utf-8") as f:
        cfg = json.load(f)
    # a test build's own dates: tools/test.json while a test runs, else go-live today
    if mode in ("test", "beta"):
        cfg.pop("wakeUp", None)
        if os.path.exists(TEST):
            with open(TEST, encoding="utf-8") as f:
                cfg.update(json.load(f))
        else:
            cfg["goLive"] = datetime.date.today().isoformat()
    args = argv[1:]
    while args:
        a = args.pop(0)
        if a == "--version":
            cfg["version"] = args.pop(0)
        elif a == "--go-live":
            cfg["goLive"] = args.pop(0)
        elif a == "--wake-up":
            cfg["wakeUp"] = args.pop(0)
        elif a == "--important":
            cfg["important"] = True
        else:
            sys.exit("unknown option " + a)
    go_live = datetime.date.fromisoformat(cfg["goLive"])
    if cfg.get("wakeUp"):
        if datetime.date.fromisoformat(cfg["wakeUp"]) <= go_live:
            sys.exit("the wake-up day must come after go-live")

    test = mode != "release"
    tools = mode in ("dev", "test")
    # a release needs its changes written down first; test and beta builds show them if so
    changes = changes_of(cfg["version"], required=mode == "release") if mode != "dev" else None
    seed, public = load_key("test.key" if test else "release.key", create=test)

    num = cfg["questPack"]
    data = build_pack(num)
    pack_sig = ed25519.sign(seed, data)
    stamp_sig = ed25519.sign(seed, stamp_body(cfg))
    assert ed25519.verify(public, data, pack_sig)

    if mode == "dev":
        write_packdata(os.path.join(SRC, "Quests", "PackData.lua"), num, data, pack_sig)
        write_build(os.path.join(SRC, "Core", "Build.lua"), cfg, True, True, public, None)
        print("wrote the dev quest pack (%d bytes, %d templates) and Build.lua into src/"
              % (len(data), len(load_templates()[0])))
        return 0
    copy_dist(cfg, test, tools, public, stamp_sig, num, data, pack_sig, changes)
    if mode == "beta":
        zip_dist("PintoTGD-beta.zip")
    elif mode == "release":
        zip_dist("PintoTGD-%s.zip" % cfg["version"])
        update_readme(cfg["version"], changes)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
