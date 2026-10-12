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
| `/fp remove Name-Realm` | Forget a character |

## Good to know

- The bank and recipes can only be read while they're open in game, so they show
  what was there the last time that character visited a banker or opened that profession.
- Sync only happens while you're both online and connected (same guild, group, or friends list).
  Otherwise you see their last snapshot.
