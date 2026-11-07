# heatsync chatterino plugin

heatsync inside chatterino — one lua plugin, no fork, no patched binary. your emote inventory tab-completes everywhere; on a build with rendering apis, heatsync emotes show as real images and kick + youtube chat merges into your twitch tabs.

## install

1. download [heatsync.zip](https://github.com/mellen9999/heatsync-chatterino/releases/latest/download/heatsync.zip)
2. unzip it into chatterino's `Plugins` folder, so you end up with a `heatsync` folder inside `Plugins`:
   - windows — press `win+r`, paste `%APPDATA%\Chatterino2\Plugins`, enter
   - linux — `~/.local/share/chatterino/Plugins/`
   - macos — `~/Library/Application Support/chatterino/Plugins/`

   (no `Plugins` folder yet? make one with exactly that name)
3. restart chatterino → settings (⚙) → plugins → tick "enable plugins" → enable **heatsync**
4. type `/hshelp` in any chat

update: repeat 1–2 (replace the old `heatsync` folder), restart chatterino.
from source: clone this repo into `Plugins/heatsync`.

## what your build gets

the plugin asks the chatterino binary what it can do at boot and degrades one feature at a time. `/hsstatus` shows what's active.

| the build exposes… | you get |
|---|---|
| message rendering + image apis | everything below |
| websocket + message injection | live-synced tab-complete, `/hsmulti`, live status, `/hsmoments`, `/hslogs` |
| commands only | tab-complete from your inventory + the global catalog |

## features

- **tab-complete** — your inventory first (usage-weighted), then the 7tv/bttv/ffz catalog. a leading `:` is optional
- **inline emotes** — a word renders iff the *sender's* heatsync inventory has it (the extension's rule). the catalog is for completion only, never rendering. click any emote the plugin draws to insert it. twitch emotes, badges and replies pass through untouched
- **live sync** — add an emote on heatsync.org and it's usable here within seconds
- **multichat** — kick and youtube chat merged into a twitch tab, tagged `[K]` / `[Y]`, with the last ~50 lines of history. auto-merges where a streamer publicly linked their accounts
- **markers** — `>>id` threadlinks, 🔥 on heatsync users, heat bars and sub-flair badges before names, youtube name colors, mention highlights on merged lines
- **pinned message**, **live status** (go-live, game and title changes), **moments** (chat spikes)
- **community mutes**, **inline images**, **link previews**, **gifs** — see commands
- **right-click → heatsync** — a chatter's emotes, logs, whois; block an emote (builds with plugin context menus)
- **optional login** — synced notes, mutes, emote blocks, mention rules, follows, pinning

can't do (needs a fork): settings ui, username paints, chatterino's own emote picker, anything needing the site's cookie session. zero-width overlays render as normal images and emote modifiers (`w!`, `h!`, `ffzX`…) are named in the tooltip but not applied.

## commands

| command | what |
|---|---|
| `/hsemotes [page\|query]` | your inventory as a clickable grid, recents first |
| `/hsfind <query>` | inventory + catalog search, click to insert |
| `/hsgif [query] [page]` | heatsync's gif library as stills (12/page, up to page 4); click inserts the url. heatsync's own library, so giphy/tenor never see you |
| `/hsinv <user> [page]` | anyone's heatsync emotes |
| `/hssearch <query>` | search heatsync posts |
| `/hschat <query> [@user] [#channel]` | search the chat archive; also the server's `from:` `in:` `has:` `before:` `after:` |
| `/hslayout <link>` \| `share` | open a heatsync.org/m/… link, or build one for this tab |
| `/hsmulti kick:<slug>` \| `yt:<handle>` \| `off` \| `auto on\|off` | merge kick/youtube chat into this tab |
| `/hshot [platform] [page]` | hottest live streams, heat-ranked |
| `/hswhois <user>` · `/hscard <user>` | heatsync profile · full card (heat, posts, followers, followage, archive stats, last lines) |
| `/hsmoments [<n>h] [platform] [page]` | top chat moments |
| `/hslogs <user> [channel]` | chatter stats + archive link |
| `/hsblock <name>` · `/hsunblock` · `/hsblocklist` | hide an emote (render + completion); local, plus your account when logged in |
| `/hslogin` · `/hslogout` | login (below) |
| `/hsnote <user> [text\|-]` | private note on a chatter — view / set / clear (login) |
| `/hsmute <user> [twitch\|kick\|yt]` · `/hsunmute` · `/hsmutelist` | your account's mutes (login) |
| `/hsfollow <user>` · `/hsunfollow <user>` | follow on heatsync (login) |
| `/hspin clear [kick:<slug>]` | remove the channel's pin (moderators, login). to pin: right-click a line → heatsync → pin message |
| `/hshelp` · `/hsstatus` · `/hsrefresh` · `/hsclear` · `/hsdump` · `/hstest` | index · capability report · refetch inventory · clear caches · dump last message's elements · render self-test |

toggles — `/hs<name> on|off`:

| toggle | does | default |
|---|---|---|
| `flame` | 🔥 before heatsync users | on |
| `heat` | heat bar before names with 5+ heat | on |
| `flair` | sub-flair badge before names | on |
| `colors` | picked name color on merged youtube lines | on |
| `mentions` | chatterino's mention highlight on merged lines that ping you | on |
| `backfill` | load a merged source's last ~50 lines | on |
| `pin` | the channel's heatsync pin as a 📌 line | on |
| `archive` | tell heatsync which public twitch channel you watch so it archives it | on |
| `live` | 🔴/⚫ for linked kick/youtube, 🎮/📝 game and title changes (also open twitch tabs) | off |
| `moments` | 🔥 line when a chat spikes | off |
| `mutes` | collapse lines from chatters the channel's community muted | off |
| `images` | show image links inline, loaded through heatsync (20 new urls/min) | off |
| `previews` | title + thumbnail under non-image links (10 new links/min) | off |

## log in (optional)

everything works without an account. login unlocks notes, account mutes, synced emote blocks, mention rules, follows and pinning.

1. type `/hslogin` — it prints a code and a link
2. open the link (heatsync.org/cli), sign in, enter the code, tick `account` (`chat` and `mod` are optional), approve
3. back in chatterino it says `logged in as <you>` within seconds

`/hsstatus` shows your login; `/hslogout` signs out and revokes the token (or revoke at heatsync.org/cli).

- the token goes only in an `Authorization: Bearer` header to `https://heatsync.org/api/cli/…`. never on the websocket, never logged or printed
- it's stored as plain text in `Plugins/heatsync/data/account.txt`, like any chat client's token — treat it like a saved password
- it lasts 30 days and renews itself near the end, up to 90 days after first login; then `/hslogin` again

## privacy

permissions: `Network` (heatsync.org + one anonymous websocket) and `FilesystemRead` / `FilesystemWrite` (settings, block list, multichat links, recents, and the login token if you log in — all in the plugin's own data folder).

what leaves chatterino:

- your twitch login — to sync your emote inventory
- `archive` on: the name of the public twitch channel you're watching, at most once per 5 minutes. never message text, usernames or ids
- `heat` / `flair` / `colors` on: logins and ids of chatters in your open tabs, in small batches
- `images` / `previews` on: the link goes to heatsync, which fetches and scans it and serves the image — the linked site never sees your ip, heatsync sees the link
- `mutes` on: open channel names, nothing else
- `/hsgif` sends your query; `/hscard` the login you ask about; merged-source history the source's channel name
- logged in: the token, plus what each account command carries (the chatter, note text, emote hash, message id)
- nothing else — no whispers or dms, no browsing history, no telemetry. logged out, no token exists and the socket is anonymous

## develop

no build step, lua 5.4. a headless harness stubs the chatterino api and drives the real modules (including fuzzed input and fixtures from real heatsync.org responses); it strips `os` like chatterino does:

```
lua5.4 test/harness.lua
TIER=t1 lua5.4 test/harness-degrade.lua
TIER=t0 lua5.4 test/harness-degrade.lua
```

`./release.sh` builds `dist/heatsync.zip` (tests gate it); `./release.sh publish` tags and uploads it.

mit
