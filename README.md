# Pinto, the Girthy Dragon

Pinto is a World of Warcraft: Forever addon for The Girthy Dragons, an EU PVE guild. It's kind of like a Tamagotchi of our mascot Pinto who we all take care of together!
His wellbeing shows through him getting fatter when guildies play together, and his hoard grows with the guild's wealth. Each character gets four quests a week that ask them to play with guildies, and finished quests feed him. There are no leaderboards or personal scores.

<!-- whats-new: tools/build.py release writes this part, from CHANGELOG.md -->
## What's new in 0.1.1

- Notices beside the minimap button now take turns: each one finishes and slides away before the next comes in.
- Pinto tells you once per login when a newer version is out. Click the notice for the download link.
- If your finished quests have waited an hour, Pinto reminds you to open the window and feed him, though never during or just after a fight.
- The very first time you run Pinto, the notice shows you where he lives.
- Clicking a notice opens Pinto.
- The guild's pile now grows while you watch, as each of your haunches lands.
- "Your contribution so far" now sits under your pile, clear of the quest list, and the small window leaves it out.
- Future versions of Pinto can tell yours about an update even if they change how Pinto's data or messages work.

Every release's changes are in [CHANGELOG.md](CHANGELOG.md).
<!-- /whats-new -->

## For anyone checking the code

The addon is plain, readable Lua in `src/PintoTGD/`. The build ships it as is, apart from the version in the `.toc` and two files it writes, `Core/Build.lua` and `Quests/PackData.lua`.

- **Pinto is completely in-game.** Guildies' copies of Pinto share data only through the game's addon messages, on the guild channel and in whispers (`Sync/`).
- **What it records** (`Track/`): who from the guild you group with, dungeon runs and boss kills, trades with guildies that help a quest, the days and rough hours you play, and your characters' levels, gear item levels, professions and gold bracket. It does this ONLY to the ends of feeding Pinto. Pinto does not read the combat log.
- **Saved data** in `PintoTGD_DB` is compactly encoded (`Data/`). The code itself is left unobfuscated for transparency.
- **Signed updates.** Quest packs and release notices are signed, and addons check them with Ed25519 in plain Lua (`Sync/Crypto.lua`) against the public key in `Core/Build.lua`.
- **It leaves the game's UI alone.** Pinto draws in its own frames and adds nothing to the game but its `/pinto` command and Escape-to-close entries for its windows. An offline test checks this.

## More

`docs/dev.md` describes the code's rules. `lua tools/sim/run.lua` runs the offline tests against a simulated game client.
