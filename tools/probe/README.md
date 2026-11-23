# Pinto Probe

Milestone 0: a small addon that checks what the WoW: Forever client offers Pinto, before Pinto relies on it.

The probe never pops up an error. When something is missing, it notes it in its log and says so once in the chat. Missing pieces are what it's here to find.

It also logs what the Forever client keeps from addons:
- **Hidden values:** which events carry values addons can't read, and where (instance, combat, boss fight).
- **Blocked actions:** any action the game blocks, for any addon.
- **Chat lockdown:** when addon messages are locked down.

It never registers the combat log, because Forever blocks any addon that does.

Forever has no realms, and every character is "Name Surname". A few seconds after login the probe sends itself two addon whispers, one to "Name Surname" and one to "Name-Surname". It also sends one addon message to the guild. This shows which whisper arrives and how the game names the sender. The whisper that doesn't arrive may print one "No player named ..." line in the chat; that's expected.

## Build and install

```
python tools/build.py probe
```

This puts `PintoProbe` in `dist/`. Copy that folder to the client's `Interface\AddOns\`, replacing any older copy. A new probe version starts a fresh log.

## In the game

On a character in The Girthy Dragons:

1. Log in. The probe says which version is logging, and checks the client quietly a few seconds later.
2. Type `/pintoprobe`. It checks again and prints a summary: what's missing from what Pinto uses, the events the client doesn't have, your name as the roster gives it, and which addon messages to yourself arrived.
3. Type `/pintoprobe show`. A test frame shows a rotated bar, an ellipse, a slanted triangle, a circle-masked square and a line. Take a screenshot.
4. Type `/pintoprobe crypto`. It times one Ed25519 check.
5. Then play a little, so the probe can log the events Pinto's tracking needs. These help, if they happen naturally. The probe keeps the first 12 trade windows and group changes, so do the ones that matter early in a session:
   - run a dungeon with a guildie, ideally to the last boss. This records encounter ids for Pinto's final-boss table, what the client hides inside instances, and whether addon messages are locked down during boss fights or in the whole dungeon.
   - if you're an enchanter, enchant a guildie's item in the trade window's "will not be traded" slot, or have one enchant yours
   - craft something with the profession window open
   - fish, mine, pick herbs or skin
   - bandage a party member: target them, then use the bandage
   - watch for someone joining the guild
6. Type `/reload`. WoW writes `WTF\Account\<account>\SavedVariables\PintoProbe.lua`. Send that file over.

## By hand, at the trainers

At a crafting trainer and a gathering trainer, note each rank's skill cap and the level it needs (Apprentice, Journeyman, Expert, Artisan). That confirms Pinto's cap(L) table.
