"""Makes the next Pinto release ready to push, in one go. Double-click release.cmd, or run
python tools/release.py.

First write the release's changes in CHANGELOG.md, under a new heading at the top:
"## <version>", or "## <version> (important)" for a fix everyone needs. Then this:
  1. sets tools/release.json to that version, and the dev build in src/ with it;
  2. runs the offline tests, and stops if any fail;
  3. builds and signs the release (tools/build.py release): the zip in dist/, its
     signatures in tools/signatures.json and its changes in the README's "What's new";
  4. offers to put it in your AddOns folder.
Then commit and push it all. On GitHub, .github/workflows/release.yml builds the same
release from the pushed source with those signatures, publishes it with the zip, and
sends it to CurseForge.

  --skip-tests   leaves out step 2
  --no-install   leaves out step 4 without asking
"""
import json
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS = os.path.join(ROOT, "tools")
sys.path.insert(0, TOOLS)
import changelog  # noqa: E402
import curseforge  # noqa: E402

RELEASE = os.path.join(TOOLS, "release.json")
ADDONS = os.environ.get("PINTO_ADDONS") or r"C:\Program Files\World of Warcraft\_forever_\Interface\AddOns"
LUA_PLACES = [r"C:\Program Files\Lua\bin\lua.exe"]


def say(text):
    print(text)
    sys.stdout.flush()


def stop(text):
    sys.exit("\nStopped: " + text)


def number(version):
    m = re.match(r"^(\d+)\.(\d+)\.(\d+)$", version)
    return tuple(int(x) for x in m.groups()) if m else None


def out_already(version):
    """Whether GitHub has the version's tag: True, False, or None if it can't tell."""
    try:
        p = subprocess.run(["git", "ls-remote", "--tags", "origin", "refs/tags/v" + version],
                           cwd=ROOT, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if p.returncode != 0:
        return None
    return bool(p.stdout.strip())


def run(args, what):
    if subprocess.run(args, cwd=ROOT).returncode != 0:
        stop(what + " failed: see above.")


def run_tests():
    lua = shutil.which("lua") or next((p for p in LUA_PLACES if os.path.exists(p)), None)
    if not lua:
        say("Couldn't find Lua, so the offline tests didn't run.")
        return
    say("Running the offline tests (a few minutes)...")
    p = subprocess.run([lua, os.path.join("tools", "sim", "run.lua")], cwd=ROOT, capture_output=True, text=True)
    lines = (p.stdout + p.stderr).strip().splitlines()
    fails = [line.strip() for line in lines if line.strip().startswith("FAIL")]
    say("  " + (lines[-1] if lines else "no output"))
    if p.returncode != 0 or fails:
        for line in fails[:20]:
            say("  " + line)
        stop("the tests failed.")


def install(version):
    if not os.path.isdir(ADDONS):
        say("No AddOns folder at %s, so nothing was installed." % ADDONS)
        return
    say("\nPinto %s can go in your AddOns folder now. If it does, push before you log in with it," % version)
    say("and wait until GitHub shows the release: your copy tells the guild it's out.")
    if input("Put it in your AddOns folder? [y/N] ").strip().lower() not in ("y", "yes"):
        return
    target = os.path.join(ADDONS, "PintoTGD")
    if os.path.isdir(target):
        shutil.rmtree(target)
    shutil.copytree(os.path.join(ROOT, "dist", "PintoTGD"), target)
    say("Installed in " + target)


def main(argv):
    with open(os.path.join(ROOT, "CHANGELOG.md"), encoding="utf-8") as f:
        log = f.read()
    heads = changelog.headings(log)
    if not heads:
        stop("CHANGELOG.md has no \"## <version>\" headings.")
    version = heads[0][0]
    if not number(version):
        stop("the newest heading in CHANGELOG.md, %r, isn't a version like 0.1.2." % version)
    if not changelog.section(log, version):
        stop("CHANGELOG.md has no changes under \"## %s\"." % version)
    with open(RELEASE, encoding="utf-8") as f:
        cfg = json.load(f)
    if number(version) < number(cfg["version"]):
        stop("CHANGELOG.md's newest version, %s, is older than release.json's, %s." % (version, cfg["version"]))
    out = out_already(version)
    if out:
        stop("%s is out already. Write the next version's changes under a new heading at the top "
             "of CHANGELOG.md first." % version)
    if out is None:
        say("(Couldn't ask GitHub whether %s is out yet, so carrying on.)" % version)

    important = changelog.important(log, version)
    if cfg["version"] != version or cfg.get("important", False) != important:
        cfg["version"], cfg["important"] = version, important
        with open(RELEASE, "w", encoding="utf-8", newline="\n") as f:
            f.write(json.dumps(cfg, indent=2) + "\n")
    say("Pinto %s%s\n" % (version, ", an important fix" if important else ""))

    run([sys.executable, "-I", os.path.join("tools", "build.py"), "dev"], "The dev build")
    if "--skip-tests" not in argv:
        run_tests()
    run([sys.executable, "-I", os.path.join("tools", "build.py"), "release"], "The release build")
    zip_path = os.path.join(ROOT, "dist", "PintoTGD-%s.zip" % version)
    game = curseforge.check_zip(zip_path, version)
    say("Checked: %s is a signed release build, for game version %s." % (os.path.basename(zip_path), game))
    if "--no-install" not in argv:
        install(version)

    say("\nReady. To publish %s, commit and push it all, with tools/release.json, tools/signatures.json," % version)
    say("README.md and src/PintoTGD/Core/Build.lua. GitHub then builds the release from what you pushed,")
    say("publishes it with the zip and sends it to CurseForge: the Actions tab shows how it went.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
