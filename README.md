# FriendProgress

A World of Warcraft: Forever addon that shows your friends' progress in one place:
level and XP, gear, bags, bank, professions and recipes, quests, and an activity feed.

Everyone you want to see needs FriendProgress installed too. Data syncs over hidden
addon messages through your guild, your group and your in-game friends list.

## Install

1. Download this repository (Code > Download ZIP) and extract it.
2. Rename the extracted folder to `FriendProgress` if needed (GitHub adds `-main`).
3. Move it to `World of Warcraft\_classic_beta_\Interface\AddOns\`.
   The folder must contain `FriendProgress.toc` directly.
4. Restart the game or type `/reload`.

## Using it

- `/fp` opens the window. Right-click a character to add them to a friend group.
- **Sharing...** chooses what you send to others (bags: everything, crafting materials only, or nothing; same for the bank).
- The party XP box shows live XP for you and your party. Unlock it in **Sharing...** to move it.

| Command | What it does |
|---|---|
| `/fp` | Open or close the window |
| `/fp sync` | Rescan yourself and ask friends for updates |
| `/fp craft <name>` | Who can craft something |
| `/fp share` | Sharing settings |
| `/fp xp` | Show or hide the party XP box |
| `/fp button` | Show or hide the on-screen sync button |
| `/fp unlock`, `/fp lock` | Move the on-screen frames |
| `/fp autosync <minutes>` | Background sync interval, `0` = off |
| `/fp notify` | Chat notifications for friends' activity |
| `/fp deaths` | Death log |
| `/fp deaths alerts` | On-screen death alerts on or off |
| `/fp deaths jokes` | Jokes in death alerts on or off |
| `/fp deaths test` | Preview a death alert (and test the Discord relay) |
| `/fp deaths debug` | Show what death detection has seen (last hit, attacker, falls) |
| `/fp discord` | Post your deaths to Discord on or off (needs the relay, see below) |
| `/fp remove Name-Realm` | Forget a character |

## Death log and Discord

When you die, FriendProgress tells everyone you sync with who or what killed you,
your level and the zone. They get a raid-warning style alert, and every death is
kept in the **Deaths** tab. Turn off **Announce my deaths** in **Sharing...** to keep yours private.

### Posting your deaths to Discord

Everyone who wants their deaths posted installs a small relay on their own PC.
Addons can't reach the internet, so your addon saves your deaths in its saved data
and the relay posts them to Discord. WoW only writes that data to disk on `/reload`,
logout or exit, so **releasing spirit reloads your UI** (a few seconds, while you're a ghost anyway)
and the post goes out right after. If you're resurrected instead, it posts at your next reload or logout.

1. Get the webhook URL from whoever runs the Discord server. To make one: channel settings >
   Integrations > Webhooks > New Webhook > Copy Webhook URL. Only share it with friends:
   anyone with the URL can post in that channel.
2. Double-click `Install.cmd` in the addon's `discord` folder and paste the URL when asked.
   It finds your WoW folder, then runs the relay hidden in the background, now and whenever Windows starts.
3. In game, type `/fp discord` (once; it covers all your characters).
4. `/fp deaths test` reloads your UI, and a "[Test]" post should appear within a few seconds.

Run `Install.cmd` again to change the webhook or after updating the addon. `Uninstall.cmd` removes
the relay. If nothing posts, look at `%LOCALAPPDATA%\FriendProgress\relay.log`.

### Jokes

Death alerts in game and Discord posts each get a joke picked to match the death: falls,
drowning, murlocs, Hogger, getting killed by something far below your level, your tenth death,
and so on. Turn them off in game with `/fp deaths jokes` (or in **Sharing...**), and in Discord
by adding `"humour": false` to `%LOCALAPPDATA%\FriendProgress\DeathRelay.config.json`.

The jokes live in `discord\DeathQuips.json`. `_killers` maps patterns in the killer's name to a
category. After editing it, run the line below to update the in-game copy (`DeathQuips.lua`),
then send the changes in so everyone gets them:
```
powershell -ExecutionPolicy Bypass -File tools\Build-Quips.ps1
```

## Good to know

- The bank and recipes can only be read while they're open in game, so they show
  what was there the last time that character visited a banker or opened that profession.
- Sync only happens while you're both online and connected (same guild, group, or friends list).
  Otherwise you see their last snapshot.
