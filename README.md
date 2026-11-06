# FriendProgress

A World of Warcraft: Forever addon that shows your friends' progress in one place:
level and XP, gear, bags, bank, professions and recipes, quests, and an activity feed.

Everyone you want to see needs FriendProgress installed too. Data syncs over hidden
addon messages through your guild, your group (up to 5), your in-game character friends list,
and your Battle.net friends who are playing WoW Forever (on any realm). Character friends
need to be added on both sides. Turn off **Battle.net friends** in **Sharing...** to sync only
with your guild, group and character friends.

## Install

### With WowUp

1. In WowUp, select your `_classic_beta_` install.
2. Go to **Get Addons**, choose **Install from URL** and paste `https://github.com/s-abbo-92/FriendProgress`.

WowUp then offers updates whenever a new release is published. Carry on from step 3 below.

### By hand

1. Download `FriendProgress-<version>-forever.zip` from the repository's Releases page, or get
   `FriendProgress-<version>.zip` from whoever shares it with you.
2. Close WoW, then extract the zip into `World of Warcraft\_classic_beta_\Interface\AddOns\`
   (usually `C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns\`).
   You should end up with `AddOns\FriendProgress\FriendProgress.toc` and not an extra folder level.
   To update, delete the old `FriendProgress` folder first.
3. Start the game. If FriendProgress shows as out of date on the character select screen,
   tick **Load out of date AddOns**.
4. Type `/fp` in game to open it. Type `/fp sync` once your friends have it installed too.
5. Optional: to post your deaths to Discord, see [Posting your deaths to Discord](#posting-your-deaths-to-discord).

The `discord` folder inside the addon is only used by the optional Discord relay (Windows only).
WoW ignores it, so leave it where it is.

Everyone you sync with should be on the same version; older versions ignore some newer data.

## Using it

- `/fp` opens the window. Right-click a character to add them to a friend group.
- **Sharing...** chooses what you send to others (bags: everything, crafting materials only, or nothing; same for the bank).
- The party XP box shows live XP for you and your party. Unlock it in **Sharing...** to move it.
- On the Professions tab, click the [+] next to a recipe to see its materials and how many that player
  has across bags and bank. Materials are recorded when they open that profession window, and the
  counts need their bags shared.
- The Overview tab estimates XP per hour and time to next level from the last hour of play, once
  you've played for 5 minutes. Quest XP arrives in big lumps, so treat it as a rough guide.

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
| `/fp bnet` | Show which Battle.net friends sync can see and who it has heard from |
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
- Sync only happens while you're both online and connected (same guild, group, character
  friends list, or Battle.net friends both in WoW Forever).
  Otherwise you see their last snapshot.

## Making a release

1. Bump `## Version:` in `FriendProgress.toc` and `ns.VERSION` in `Core.lua` (they must match).
2. Commit and push, then tag that commit with the same version:
   ```
   git tag v0.3.2
   git push origin v0.3.2
   ```

GitHub Actions checks the tag matches both version numbers, builds the zip and publishes it as a
GitHub Release, which is what WowUp updates from. Tags containing `alpha` or `beta` become
pre-releases, which WowUp's Stable channel skips.

To build a zip locally instead, commit, then run:
```
powershell -ExecutionPolicy Bypass -File tools\Package.ps1
```
That writes `dist\FriendProgress-<version>.zip` from the last commit, so uncommitted changes aren't in it.
