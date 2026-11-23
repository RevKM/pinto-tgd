# Pinto, the Girthy Dragon

Pinto is a World of Warcraft: Forever addon for one guild, The Girthy Dragons. It shows the guild's social health as a dragon on a gold hoard: he gets fatter when guildies play together, and his hoard grows with the guild's wealth. Each character gets four quests a week that ask them to play with guildies, and finished quests feed him. There are no leaderboards or personal scores.

## For anyone checking the code

The addon is plain, readable Lua in `src/PintoTGD/`. The build ships it as is, apart from the version in the `.toc` and two files it writes, `Core/Build.lua` and `Quests/PackData.lua`. Worth knowing:

- **It stays inside the game.** Guildies' copies of Pinto share data only through the game's addon messages, on the guild channel and in whispers (`Sync/`).
- **What it records** (`Track/`): who from the guild you group with, dungeon runs and boss kills, trades with guildies that help a quest, the days and rough hours you play, and your characters' levels, gear item levels, professions and gold bracket. It never reads the combat log.
- **Saved data** in `PintoTGD_DB` is compactly encoded (`Data/`). The code itself is never obfuscated.
- **Signed updates.** Quest packs and release notices are signed, and addons check them with Ed25519 in plain Lua (`Sync/Crypto.lua`) against the public key in `Core/Build.lua`.
- **It leaves the game's UI alone.** Pinto draws in its own frames and adds nothing to the game but its `/pinto` command and Escape-to-close entries for its windows. An offline test checks this.

## More

`PLAN.md` describes the design, and `docs/dev.md` the code's rules. `lua tools/sim/run.lua` runs the offline tests against a simulated game client.
