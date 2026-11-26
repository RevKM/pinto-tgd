# Developer notes

How the code is laid out and the rules it follows. PLAN.md says what the addon does; this file says where things live. Dev-only: the build never ships `docs/`.

## Layout

```
src/PintoTGD/
  PintoTGD.toc      load order
  Core/             Init (namespace, versions, events, timers), Compat (WoW API differences),
                    Util, Time (server days and weeks)
  Sync/             Bytes (binary writer and reader), Crypto (SHA-512, Ed25519 check),
                    Comm (prefix, pacing, multi-part messages), Protocol (hello, live facts, catch-up)
  Data/             Store (facts, values, pieces, fingerprints, pruning, saving)
  migrations/       one migration contract per data version
  Track/            Roster, Player, Activity (who's nearby, groups, camps, dances and cheering),
                    Trades, Guild (invites, the guild bank), Trace (what the game says inside
                    instances, kept locally), Gear and professions
  Health/           Formula (H and its parts), Health (history, too few players,
                    calibration, wealth, feeding and mood)
  Quests/           Blocks, Pack, PackData (written by the build), Roll, Progress
  Render/           Pinto's scene, ported from the demo
  UI/               minimap button and its notices (Minimap: the note and its queue; Notices:
                    a newer version, quests waiting to be eaten), small and full windows (and
                    the start notice), quest list, eating chain, popups, officer corner,
                    debug panel and test controls
  Media/            textures, made by tools/textures.py, and the cave backdrop by tools/backdrop.py
  Main.lua          wiring and slash commands
quests/             quest templates, one file per set
keys/               signing keys (dev only, never published)
tools/
  build.py          builds dist/ and signs the quest pack and release stamp
  ed25519.py        signing in pure Python (RFC 8032)
  changelog.py      reads a release's changes from CHANGELOG.md
  release.py        makes the next release ready to push (release.cmd runs it)
  signatures.json   the newest release's signatures, for GitHub's build of it
  curseforge.py     uploads a release zip to CurseForge, for .github/workflows/curseforge.yml
  textures.py       draws the TGA textures in Media/
  backdrop.py       makes Media/Cave.tga and its fade mask from art/cave.png
  release.json      the release: version, go-live date, quest pack number, update link and
                    the release key's public half
  test.json         a running test's dates, for test and beta builds: go-live and wake-up
  art/              source pictures: the cave
  probe/            the probe addon (milestone 0)
  sim/              offline tests: compat.lua, harness.lua, run.lua, wow.lua (WoW API stubs),
                    uistub.lua (UI widget stubs), test_*.lua
.github/workflows/  release.yml: builds and publishes each new release when it's pushed;
                    curseforge.yml: sends each published release to CurseForge
CHANGELOG.md        every release's changes, newest first
release.cmd         double-click to make the next release ready (tools/release.py)
dist/               build output, kept out of git (releases go up as zips)
```

## Rules for addon code

WoW runs Lua 5.1, and the offline tests run on Lua 5.5 through `tools/sim/compat.lua`. So:

- **Lua 5.1 only.** No `goto`, no `//`, no bitwise operators, no `table.unpack` (use `unpack`), no integer-only behavior. Never assign to a `for` loop variable: Lua 5.5 refuses to compile it.
- **Numbers are doubles.** Keep whole-number math below 2^53.
- **Bit operations** use WoW's `bit` library. Its results may come back signed or unsigned, so normalize with `% 4294967296` before comparing or doing arithmetic. Pass only whole numbers between -2^31 and 2^32-1.
- **Numbers to text** with `string.format`, never with `..` or `tostring` on a computed number: modern Lua prints `3.0` where WoW prints `3`. Use `%d` only below 2^31 (WoW's `%d` is 32-bit); use `%.0f` for larger whole numbers such as ids.
- **Sorting strings** for anything that must come out the same on every client (encodings, fingerprints) uses `ns.Util.byteLess`, not `<`, because Lua 5.1 compares strings with the system locale.
- **One namespace.** Each file starts with `local ADDON, ns = ...` and adds its module to `ns` (`ns.Bytes`, `ns.Store`, ...). Everything else is local.
- **Globals:** only the SavedVariables table `PintoTGD_DB`, the slash command (`SLASH_PINTO1`, `SlashCmdList.PINTO`) and named top-level frames that Escape should close. Never assign one of the game's globals, not even to put back the value it has (`SlashCmdList = SlashCmdList or {}`): WoW taints a global an addon writes, and the game's code that reads it then can't call protected functions, so slash commands like `/pvp` get blocked, with Pinto blamed. Add to the game's tables only under Pinto's own keys. The stand-in client notes every global the addon writes (`client.globalWrites`) and every change to the game's own tables (`client:gameTableChanges()`), and a UI test checks both.
- **The game's shared UI.** Pinto has its own tooltip (`UI.ShowTip`) and its own popup window (`UI.Popups`). It never uses `GameTooltip`, `StaticPopup`, the game's dropdown menus, its chat functions or option panels, or `hooksecurefunc`. An addon taints whatever it touches of those, and the game's own code that runs after it can't call protected functions. A UI test scans the code for them.
- **WoW calls that differ between clients** go through `ns.Compat`. The Forever client has no `GetSpellInfo`, so spell names come from `Compat.SpellName`; item details come from `Compat.ItemInfo`, `Compat.ItemInfoInstant` and `Compat.ItemLevel`, which try `C_Item` first. Professions come from `Compat.Professions` (`GetProfessions`, which Forever has), with the older skill lines as a fallback. The quest log comes from `Compat.QuestLog` (`C_QuestLog`, or the older `GetQuestLogTitle`), and the open trade skill's name from `Compat.TradeSkillName` (`C_TradeSkillUI`, or the older `GetTradeSkillLine`).
- **Names.** A character's key is its full name as the guild roster gives it: "Name Surname" on Forever, which has no realms (`Compat.Surnames()`), and "Name-Realm" on older clients. Make a key from any name the client gives with `Compat.FullName` or `Compat.UnitFullName`, never by joining strings; they also read "Name-Surname" and a realm tacked on. Show a name with `Compat.ShortName`, which keeps the surname, since first names repeat. Whispers go through `Comm`, which names the target the way its login check found arrives (`Compat.WhisperTarget`).
- **Never register the combat log** (`COMBAT_LOG_EVENT_UNFILTERED`, `COMBAT_LOG_EVENT`). Forever blocks any addon that does, with the game's "blocked action" error and no Lua error, so `pcall` can't catch it. Fights and bandages are read from the player's own casts and combat state.
- **New files.** The game only finds an addon's new files when it starts. After an update in the middle of a session, a reload runs the new version without the files it added. So whatever uses a file added after 0.1.0 checks that it's there (`if ns.Trace then`), `Main.lua` leaves out a module whose file didn't load, and each calls `ns.UpdateUnfinished()`, which tells the player once per login to restart the game. A UI test runs Pinto with the file lists of 0.1.0 and 0.1.1: add every new file to its lists.
- **Events** are registered through `ns.Events.On`, which skips an event the client doesn't have and lists it in `ns.unknownEvents` (shown by `/pinto status`). A unit event Pinto needs only for the player is registered for the player alone, `Events.On(event, fn, "player")`, because other units' casts come with their spell hidden.
- **Secret values.** Forever hands addons some values as secrets, mostly in combat and in instances: chat text, spell targets, unit GUIDs and names, map ids. Reading, comparing, searching or printing one raises an error. The event dispatcher skips any event with a secret among the arguments Pinto reads (the `READS` table in `Core/Init.lua`), and passes others on as nil. Unit and map calls go through Compat, which gives nil, or false for maps, while a value is hidden. Check with `ns.Secret(v)` before using any other value that could be one, and before anything else is done with it: `not v`, `v or x` and `v == nil` raise the error too. The stand-in client's secrets can't catch those three (Lua has no hook for them), so that order is kept by reading the code, and game calls whose answer may be hidden stay in Compat.
- **Who's nearby.** A guildie in the group counts as nearby while they're in the same zone or instance (`Activity.Present`). Inside an instance Forever gives Pinto no usable map for anyone, so the maps alone can't say: 0.1.1 went by them and logged no dungeon run at all. Pinto now asks several things: the same map, in sight (`UnitIsVisible`), in range (`UnitInRange`), and, where the maps don't settle it, the zone the guild roster shows for the guildie against the player's own. Offline is elsewhere at once; another map in the open world, or another roster zone, is elsewhere once it has been so for 45 seconds, which covers a group walking into a dungeon one by one and the roster running behind. While the game gives no clear answer, the last one stands. A unit's name is remembered while the client hides it. The minimap button's tooltip shows what Pinto makes of the group and which answer decided, and `/pinto nearby` prints the same; both point out anyone the game puts in the guild whom the roster Pinto has doesn't list. The tooltip is the way that can't go wrong: after any addon's slash command the game closes its chat box under that addon's name, and on Forever that raised an error in the game's own `ChatFrameEditBox.lua` once, when the chat box had last been used for a Battle.net whisper. No addon can prevent that for a typed command, so anything worth looking at inside a dungeon should also be reachable without typing. A roster scan the client hides part of changes nothing: the last full roster stands (`Roster.Scan`).
- **One run, one session.** Back inside a dungeon or raid left less than half an hour ago, the same day and with its final boss still standing, the earlier session carries on (`Log.Session`), so a wipe and the run back don't split a run.
- **The trace** (`Track/Trace.lua`, `PintoTGD_DB.trace`) notes what the game says about group members inside instances: the place, each guildie's answers and Pinto's verdict, each distinct picture once per visit with a count, and every boss fight with where the game says it happened. Group members who aren't guildies are only counted, with the shape of their name ("Aaaa Aaaaaa"), never the name. Next to the pictures it counts, per visit and without names, what the game answered about every group member, guildie or not (`trace.signals`): online, map, sight, range, the roster's zone and the game's own word on their guild (`Compat.UnitGuild`), split by whether the player was in combat or a boss fight. So a run with strangers shows which answers Forever gives inside an instance too. In the open world it only notes looks the maps didn't settle. It's kept on the player's computer, never shared, and capped at 240 samples and 20 visits' counts. It's there to find out how Forever reports things; once dungeon tracking is confirmed in game it can go.
- **Addon messages** wait while `Compat.ChatLockdown()` is true (boss encounters and PvP matches on Forever). A message the client refuses for a lockdown goes back in the queue. They also wait during a boss fight, `Comm.InBossFight()`: from `ENCOUNTER_START` to `ENCOUNTER_END`, a loading screen, or half an hour at most. Forever accepts messages then, reports no lockdown, and delivers nothing.
- **Player-facing text** is English and follows PLAN.md word for word where the plan gives it.

## Writing quests

Quest templates are in `quests/`, built from the blocks in `Quests/Blocks.lua`. A released block never changes meaning; new behavior gets a new block, and a version that doesn't know a block skips its quests. So each kind of moment the log notices (a camp, a dance, cheering, an invite, a deposit) has a goal block of its own: a version that can't notice one never rolls a quest it couldn't finish. Rare quests and ones that shouldn't come two weeks running use the `rare` and `not_last_week` needs.

The texts follow one style, so players can tell exactly what counts, in about as few words as the old ones:
- **"Turn in"** for finishing WoW quests, and **"quest"** for questing. A Pinto quest mentioned in a text is called a Pinto quest.
- **"Nearby in your group":** a guildie in the party or raid, in the same zone, when it counts. Nobody ever needs the same WoW quest.
- **Counts of guildies never include the player.** Where a count could be read as the party's size, say "other": "a dungeon with at least 2 other guildies".
- **Group time says how long:** "quest or do a dungeon for 10 minutes with them in your group". Group sessions count after 10 minutes together.
- **"In all"** when different things add up to one number, like fish and ore.
- **"Trade"** when an item has to go through the trade window.
- **Everything the code checks is in the text.** Advice the code doesn't check is fine, if it's short.
- **Emote quests are for English clients only** (`["locale", "en"]`): Pinto reads the English emote texts, right after "You" or the name of whoever used the emote. An emote with no text, like `/train`, can't be noticed at all.
- **Camping** (Forever): a camp is a campfire from a kit, then a camp feature within 15 minutes. Both are known by the spell the item casts when used, never by name, since the recipe that crafts the item is another spell that can carry the same name. The ids in `Track/Activity.lua` come from Wowhead's Forever database; the client's `GetItemSpell` covers a camp item whose spell isn't listed.

## Tests

From the project root:

```
lua tools/sim/run.lua            all tests
lua tools/sim/run.lua crypto     tests whose file name contains "crypto"
```

Set `PINTO_FLOATS=1` to run with WoW-style doubles, and `PINTO_BIT_SIGNED=1` for signed bit results. The crypto tests should pass in all four combinations. Set `PINTO_API=modern` for a client that has item details only through `C_Item`. Set `PINTO_NAMES=realm` for "Name-Realm" names, as on older clients; everything should pass that way too.

The stand-in client (`tools/sim/wow.lua`) follows what's known about Forever's:
- **Spell names:** it has no `GetSpellInfo`.
- **Combat log:** registering it is noted in `client.forbidden` instead of taking effect.
- **Secret values:** `wow.secret()` makes a value that errors when read, and `issecretvalue` knows it.
- **Names:** characters are "Name Surname" (`wow.full("Kiri")` gives "Kiri Forever"), and `UnitName` gives the surname second. The world options `senderForm` and `whisperForm` set how addon messages name their sender and how a whisper must name its target. A whisper that names no one gets "No player named ..." back. The client option `{ realm = ... }` puts a character on another realm behind the scenes.
- **Quest log and trade skills:** only `C_QuestLog` (`client.quests`) and `C_TradeSkillUI` (`client.tradeSkill`). `{ oldQuestLog = true }` gives the older `GetQuestLogTitle` instead.
- **Unit events:** `RegisterUnitEvent` filters by the event's first argument.
- **Client options:** `{ professions = true }` lists professions only through `GetProfessions`.
- **Client fields** a test can set: `client.target`, `client.inCombat[name]`, `client.unseen[name]` (out of sight), `client.offline[name]`, `client.inRange[name]`, `client.maps[name]` (a group member's map, `false` for none), `client.noMaps` (no map for anyone, like inside an instance), `client.zone` (the zone's name), `client.guildOf[name]` (a group member's guild, `false` for none), `client.hideMaps`, `client.hideSight`, `client.hideNames`, `client.hideGuild`, `client.hideRoster` and `client.lockdown`. `wow.ITEM_SPELLS[item]` gives an item's use spell, for `GetItemSpell`.

`test_probe.lua` runs the probe addon too: it must never raise an error, even on a client that lacks nearly every call.

## Releases

To release:
1. Write the changes in `CHANGELOG.md`, in words for players, under a new heading at the top: `## <version>`, or `## <version> (important)` for a fix everyone needs.
2. Double-click `release.cmd` (`tools/release.py`). It sets `tools/release.json` to that version, and the dev build in `src/` with it. Then it runs the offline tests, builds and signs the release (`python tools/build.py release`) and offers to put it in the AddOns folder.
3. Commit and push. On GitHub, the Release workflow (`.github/workflows/release.yml`) builds the same release from the pushed source, publishes it with its zip, and sends it to CurseForge.

The release is `dist/PintoTGD`, zipped as `dist/PintoTGD-<version>.zip`, and `dist/README.md` is the release page's text. A release build has neither of the flags under Test builds: no test tools, and the guild's real data.
- **The changelog.** The release build stops without the version's changes. It writes them into the README's "What's new" block (between the `whats-new` markers), so GitHub's front page shows the newest release's changes, and at the top of the release page's text. The CurseForge upload sends them as the file's changelog.
- **The release key** is made once, with `python tools/ed25519.py keygen keys/release.key`. That prints only the public key and never overwrites a key file. Keep a backup somewhere private: without the key, nothing new can be signed that installed copies trust. Its public half is `publicKey` in `tools/release.json`, and the release build refuses any other key.
- **The signatures.** `build.py release` writes the quest pack's and the release stamp's signatures to `tools/signatures.json`, which is committed: signatures are public, and only the key makes them. GitHub's `build.py publish` builds the release from the pushed source with them, checking them against `publicKey`. It stops if anything signed changed after `release.cmd` ran, and then `release.cmd` needs to run again. So the key never leaves this PC, and each release's zip was built from its tagged source, where anyone can check it.
- **A new release** raises `version`, and `questPack` when `quests/` changed since the last release; `release.cmd` does both, so no two different packs ever share a number. `dataVersion` and `protocolVersion` go up only with a new migration contract or message format; older copies then show the "update needed" popup at every login, as they do for an important release.
- **Older copies always hear of a newer release**, even one they can't sync with. Copies on different data or protocol versions don't sync, so the newest stamp goes to an older copy on its own, in a STAMP message (`Release.Offer`), after its hello. From there it spreads to copies on that copy's version in their sync. Hellos and STAMP messages are the two messages every version reads: they always go out under protocol version 1 (`Comm.FROZEN_PROTOCOL`) and every version reads them under it. They're frozen. A new protocol version keeps sending and reading them exactly as they are. A hello only ever grows at its end, and neither may need more than one message.
- **`goLive` never changes** after the launch: every copy counts the guild's days and weeks from it.
- **The update link** (`releaseUrl`) is built into each release; stamps don't carry one. The popup shows the link of the copy the player has.
- **CurseForge** gets each release too. The Release workflow calls `.github/workflows/curseforge.yml` once it has published a release, and a release published by hand runs it as well. It hands the release's zip to `tools/curseforge.py`, which checks that it's a signed release build of the release's version and uploads it with that version's changes from `CHANGELOG.md`. It needs the repository secret `CF_API_TOKEN` and the variable `CF_PROJECT_ID`, and finds the game version from the `.toc`'s `## Interface`. Pre-releases stay on GitHub. To send a release that's already out, run it by hand with the release's tag.

## Test builds

`python tools/build.py test` takes its go-live and wake-up days from `tools/test.json`. `python tools/build.py beta` makes the same build without the test tools, to hand to a few guildies, and zips it as `dist/PintoTGD-beta.zip`. Two flags in `Core/Build.lua` tell them apart:
- **`ns.Build.test`** keeps the data apart from release data: the message prefix (`Comm.PREFIX`) and the saved data slot (`Store.slotKey`). Test and beta builds have it, so they sync with each other.
- **`ns.Build.testTools`** switches on the test tools below. Only test builds (and `build.py dev`) have it. In a beta or release build, `/pinto test` is no command, `/pinto debug` only switches the debug messages (`ns.Debug`), and the colors picked in the debug panel are ignored.

Things test and beta builds do, for a test where nobody else has the build yet:
- **Quests follow the newest pack.** `Quests.UpgradeToNewestPack` rewrites this account's quest sets for the week from an older pack onto the newest one, a second earlier than they were rolled so the merge keeps them, and `Store.ForgetReroll` gives the reroll back.

The test tools, in test builds only:
- **The debug panel** (`/pinto debug`, `UI.ToggleDebugPanel`): sliders and buttons that drive the scene directly, and the color presets.
- **`/pinto test reroll`** gives the character its weekly reroll back (`Quests.TestGiveRerollBack`).
- **`/pinto test refresh`** rolls the character's quests for the week again (`Quests.TestRefresh`), a second earlier than the old set, with the reroll back. Not once a quest of the week is finished.
- **The test look** (`UI.Win.StartTest` / `EndTest`). While it runs, `Win.State` and `Win.Refresh` follow the look instead of the guild's state, the meat pile is the look's own (`Win.PileCount`, `Win.AddToPile`), and the eating chain eats only previews. The test controls in `UI/Debug.lua` (`Debug.BuildTestBar`) start it. `Win.TestWake` runs the end of the calibration for the look: the pile's stream, then the weight the controls set.
- **Previews** (`/pinto test complete`, `Quests.TestFinish`): finished quests kept in memory, never saved or shared. `Quests.Uneaten` lists them with `preview = true`, the quest list shows them finished, and `Quests.MarkEaten` marks them eaten in memory. Previewing starts the test look. `/pinto test reset` (`UI.TestReset`) clears both.
- **`/pinto test notice`** shows the start notice again (`Win.ShowNotice`).

Merges never remove a reroll, so a reroll another addon already has comes back with the next sync.
