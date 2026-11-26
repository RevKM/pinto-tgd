# Pinto, the Girthy Dragon

Pinto is a World of Warcraft: Forever addon for The Girthy Dragons, an EU PVE guild. It's kind of like a Tamagotchi of our mascot Pinto who we all take care of together!
His wellbeing shows through him getting fatter when guildies play together, and his hoard grows with the guild's wealth. Each character gets four quests a week that ask them to play with guildies, and finished quests feed him. There are no leaderboards or personal scores.

<!-- whats-new: tools/build.py release writes this part, from CHANGELOG.md -->
## What's new in 0.1.2

- Pinto quests now say exactly what counts. "Turn in" means finishing WoW quests. Questing or a dungeon together counts after 10 minutes in a group. A guildie only has to be nearby in your group: they never need the same quest. "In all" means the amounts add up, like fish and ore together. "Other guildies" never counts you.
- New Pinto quests: dance with 3 guildies; cheer, clap or congratulate with 3 guildies; set up camp for a guildie, with a campfire and a camp feature; and for officers, now and then, invite someone new to the guild.
- Once the guild has a bank, crafters who've used it can get a quest to put something they made in it.
- Dungeon runs: Pinto 0.1.1 lost sight of your group inside dungeons, because the game gives it no map there, so quests that ask for a dungeon run never finished. It now goes by who's in sight or in range of you, and by the zone the guild roster shows for each guildie.
- A wipe and the run back no longer split a dungeon run in two.
- Hover Pinto's minimap button while you're in a group to see which guildies he counts as nearby, and why. /pinto nearby prints the same in chat.
- The quest list now says whose quests it shows, like "Kiri's Pinto quests". Each character has its own quests, and what a character does counts for its own quests only: a dungeon run on one of your characters finishes nothing on another.
- Pinto keeps a short record of what the game tells it inside dungeons, to help fix dungeon tracking. It stays on your computer and is never shared.
- Trading food or anything else you can't wear no longer counts as giving someone a gear upgrade.
- Updating Pinto while the game is running no longer stops him from starting. He keeps working and tells you to restart the game to finish the update.
- The reworded quests come with the weekly quests from the next Monday on, also for anyone still on 0.1.1. The new quests need 0.1.2.

Every release's changes are in [CHANGELOG.md](CHANGELOG.md).
<!-- /whats-new -->

## For anyone checking the code

The addon is plain, readable Lua in `src/PintoTGD/`. The build ships it as is, apart from the version in the `.toc` and two files it writes, `Core/Build.lua` and `Quests/PackData.lua`.

- **Pinto is completely in-game.** Guildies' copies of Pinto share data only through the game's addon messages, on the guild channel and in whispers (`Sync/`).
- **What it records** (`Track/`): who from the guild you group with, dungeon runs and boss kills, trades with guildies that help a quest, the days and rough hours you play, and your characters' levels, gear item levels, professions and gold bracket. It does this ONLY to the ends of feeding Pinto. Pinto does not read the combat log. To find out how the game reports who's where inside dungeons, it also keeps a short trace of that (`Track/Trace.lua`), which stays on your computer and is never shared.
- **Saved data** in `PintoTGD_DB` is compactly encoded (`Data/`). The code itself is left unobfuscated for transparency.
- **Signed updates.** Quest packs and release notices are signed, and addons check them with Ed25519 in plain Lua (`Sync/Crypto.lua`) against the public key in `Core/Build.lua`.
- **Built in the open.** GitHub builds each release's zip from its tagged source (`.github/workflows/release.yml`). Only the signatures come from the maintainer's PC (`tools/signatures.json`), and they check out against the public key in `tools/release.json`.
- **It leaves the game's UI alone.** Pinto draws in its own frames and adds nothing to the game but its `/pinto` command and Escape-to-close entries for its windows. An offline test checks this.

## More

`docs/dev.md` describes the code's rules. `lua tools/sim/run.lua` runs the offline tests against a simulated game client.
