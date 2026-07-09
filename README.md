# heatsync chatterino plugin

heatsync inside chatterino. your emote inventory tab-completes everywhere and — on a render-capable build — heatsync emotes **render as real images** in chat (yours and every other heatsync user's), you get a **click-to-insert emote menu**, you can **browse any chatter's emotes** and **search heatsync's post + chat-log archive** (the relay writes chat in, `/hschat` reads it back) without leaving chat, plus clickable `>>id` threadlinks, a 🔥 marker on heatsync users, and **kick + youtube chat merged into your twitch tabs**.

no fork, no patched binary. one lua plugin that feature-detects the host build and degrades a capability at a time instead of breaking:

| the build exposes… | what you get |
|---|---|
| message rendering + image APIs | everything: inline emotes, the emote menu, threadlinks, live sync, multichat, commands |
| websocket + message injection | live-synced tab-complete, `/hsmulti` multichat, live status, `/hsmoments`, `/hslogs` |
| commands only | tab-complete from your inventory + the global catalog |

`/hsstatus` reports which capabilities your build exposed. nothing here assumes a version number — the plugin asks the binary what it can do at boot.

## emotes

**they render.** anything in your heatsync inventory shows as an image when you post it. so does every other chatter's — a word renders iff the *sender's* inventory has it (the same rule the browser extension uses); sender sets arrive live over the websocket and via one batched lookup per handful of new chatters. the global catalog (7TV / BTTV / FFZ) is a *completion* surface, not a render one: `/hsfind` and tab-complete let you find and insert catalog emote names, but the plugin only inline-renders the heatsync layer — native chatterino handles the real 7tv/bttv/ffz emotes a sender actually uses. (rendering arbitrary catalog words would misfire: common english words are emote names too — "lost" is a 7tv cat.)

**every emote the plugin draws is click-to-insert.** left-click one in chat, in the `/hsemotes` menu, or in a `/hsfind` result and its name drops into your input — the way emotes work in a browser. (clicks on emotes chatterino renders *natively* stay chatterino's; a plugin can't override those.)

twitch emotes, badges, timestamps, and replies pass through untouched. a message with no heatsync content is never rebuilt — the render decision is two hash lookups per word, nothing allocated on a miss.

known limits: zero-width overlay emotes render as normal inline images; username paints don't render (there's no plugin API for them, and they're not faked with colored text).

## the emote menu

`/hsemotes` opens a clickable grid of **your** inventory — recently-used first, then usage-ranked — click any emote to insert it. it's the native-emote-menu experience a plugin can reach without a fork.

- `/hsemotes` — page one
- `/hsemotes 2` — next page
- `/hsemotes <query>` — filter your inventory to matching names

recents are learned from the emotes you actually send (the only usage signal a plugin can observe — chatterino handles click-inserts itself with no callback) and persist across restarts.

## multichat — kick + youtube in your twitch tab

`/hsmulti kick:<slug>` or `/hsmulti yt:<handle>` inside a twitch channel tab merges that platform's **live chat** into the tab, tagged `[K]` / `[Y]`. heatsync already ingests kick + youtube chat; the plugin pulls it over the same anonymous websocket and injects it client-side — re-subscribing on reconnect, deduping by message id, and remembering your links across restarts.

`/hsmulti auto` (on by default) merges a stream's kick/youtube chat automatically when you open its twitch tab — but only where that streamer has *publicly linked* their cross-platform accounts on heatsync, so channels that haven't stay quiet. `/hsmulti auto off` to disable, `/hsmulti off` to unlink a tab.

chatterino has no native kick/youtube. this makes heatsync the cross-platform chat layer *inside* it. (youtube chat only exists while the channel is live.)

## live status

`/hslive on` surfaces a 🔴 line when a kick or youtube source you've merged goes live, and a ⚫ line when it goes offline — in the twitch tab it's linked to. off by default. twitch live status is left to chatterino, which shows it natively; the value here is kick/youtube, which it doesn't. the go-live signal rides the same anonymous websocket, scoped to the channels you've actually linked, so it costs nothing when off.

## live sync

add an emote on heatsync.org and it's usable in chatterino within a second — a websocket push plus a debounced re-fetch. the socket is anonymous, reconnects with jittered backoff capped at 60s, heartbeats every 25s, and recycles itself if the server goes quiet; a periodic full re-fetch reconciles anything a dropped socket missed.

## the 🔥 marker

heatsync users get a 🔥 before their name in any chat, so they're identifiable even on plain-text lines. it appears once we've seen someone post heatsync content (no lookup storm on silent chat), and never on your own messages (you know it's you). `/hsflame off` turns it off.

## commands

| command | what |
|---|---|
| `<tab>` | own inventory first (usage-weighted), then the global catalog (7TV/BTTV/FFZ, popularity-ranked) |
| `/hsemotes [page\|query]` | **your emote menu** — clickable inventory grid, recents-first; page or filter it |
| `/hsfind <query>` | **catalog search** — inventory + 7TV/BTTV/FFZ shown as images; click one to insert |
| `/hsinv <user> [page]` | **browse anyone's inventory** — a user's heatsync emotes as a click-to-insert grid, paged |
| `/hssearch <query>` | **search heatsync posts** — click a result to open the thread |
| `/hschat <query> [@user] [#channel]` | **search the chat archive** — the relayed twitch-chat corpus; click a line to open it at the exact message. narrow with `@user`/`#channel` (a bare query scopes to the current tab) |
| `/hsmulti kick:<slug>` \| `yt:<handle>` \| `off` \| `auto on\|off` | merge kick/youtube chat into this tab; `auto` links a stream's platforms automatically |
| `/hshot [platform] [page]` | hottest live streams right now (cross-platform, heat-ranked); filter by platform, page through; click a twitch one to open it |
| `/hswhois <user>` | heatsync profile card for any streamer (heat, followers, live, posts) |
| `/hsarchive on\|off` | relay the public twitch chat you view into heatsync's archive (on by default; `off` to opt out) |
| `/hsblock <name>` \| `/hsunblock` \| `/hsblocklist` | locally hide an emote (render + tab-complete) |
| `/hsflame on\|off` | toggle the 🔥 heatsync-user marker |
| `/hsbadges on\|off` | show chatterino global badges on chatters (opt-in) |
| `/hslive on\|off` | 🔴/⚫ go-live + offline lines for your linked kick/youtube sources (opt-in) |
| `/hsmoments [<n>h] [platform] [page]` | top live chat moments, clickable permalinks; `48h` sets the window, a bare number pages, filter by platform |
| `/hslogs <user> [channel]` | chatter stats (messages, channels, active days, top channels) + archive link |
| `/hshelp` | one-screen index of every command, with a note on what this build supports |
| `/hsrefresh` · `/hsstatus` · `/hsclear` · `/hsdump` · `/hstest` | inventory refetch · capability/status report · clear caches · dump last message's elements to the log · post a render self-test |

a leading `:` is optional — `:pog` and `pog` both match. `/hsstatus` also shows multichat's per-tab links and any lines it's had to drop (a tab closed mid-merge), so a merge is legible instead of silent. new to the plugin? `/hshelp`.

`/hsblock` is **local-only**: the plugin connects anonymously, so a block can't sync to your heatsync account (use the website/extension for that). that also matches how heatsync models blocks — a viewer-side render preference, not a server-side filter.

## what a plugin can't do (vs the browser extension)

the extension rewrites twitch.tv's page, so it can add right-click menus, username paints, settings panels, overlays. a chatterino plugin only has chat commands, tab-completion, and message building — **no context menus, no settings UI, no username paints, no injecting into chatterino's own emote picker, no server-synced blocks**. those need a fork, and this is deliberately not a fork. everything above is what's reachable *without* one, built to the edge of that line.

## install

1. open the chatterino plugins folder:
   - linux — `~/.local/share/chatterino/Plugins/`
   - windows — `%APPDATA%\Chatterino2\Plugins\`
   - macos — `~/Library/Application Support/chatterino/Plugins/`
2. clone or unzip this repo into a subfolder named `heatsync`:
   ```
   Plugins/
     heatsync/
       info.json
       init.lua
       *.lua
   ```
3. restart chatterino → settings → plugins → enable plugin support → enable **heatsync**, and grant its permissions.

for the full experience (rendering, the emote menu, multichat), use a build whose plugin API exposes message rendering and image loading — currently the upstream nightlies. on a build without those, the plugin still runs and gives you live-synced tab-complete and commands; `/hsstatus` tells you what's active.

## permissions & privacy

| permission | why |
|---|---|
| `Network` | public heatsync.org endpoints (`/api/profile`, `/api/users/<id>/emotes`, `/api/users/emotes/batch`, `/api/emote-search`, `/api/search`, `/api/archive/search`, `/api/moments`, `/api/live/top`, `/api/chatter/<...>/stats`, `/api/chatterino-badges`) plus one anonymous websocket for live sync and multichat. |
| `FilesystemRead` / `FilesystemWrite` | remembers your settings, block list, multichat links, and recently-used emotes in the plugin's own data folder. local only. |

**what leaves chatterino:**

- your twitch login (of the selected account) — so the server can sync your emote inventory.
- while `/hsarchive` is **on** (the default, render-capable builds only): the public twitch chat you're viewing — message text, sender login, channel, message id, timestamp — relayed into heatsync's public, searchable archive. `/hsarchive off` stops it. only chat you can already see is ever sent.
- nothing else. no auth tokens (the socket is anonymous), no whispers/DMs, no browsing history, no telemetry.

## architecture

small single-purpose modules: `caps` (feature detection), `net` (http / json / timers / data files), `inventory` (your emotes), `seventv` (catalog search + render cache), `senders` (other chatters' sets), `recents` (learned usage), `img` (image-set builder + CDN allowlist), `picker` (clickable emote grids), `ws` (socket lifecycle), `multichat` (kick/youtube injection), `live` (opt-in go-live status), `badges` (chatterino badges), `render` (hook → rebuild → replace), `store` (persisted toggles), and the command layer — `cmdutil` (shared helpers) plus `cmd_emotes` / `cmd_archive` / `cmd_multichat` / `cmd_system`, all wired by `init`. every hook is pcall-guarded and every capability is feature-detected, so a missing API degrades one feature instead of erroring. if chatterino ever exposes first-class plugin emote providers, `render.lua` is the only file that needs to change.

## tests

a headless harness stubs the chatterino API and drives the real modules — caps detection, completion, sender batching, ws dispatch/backoff, the render rebuild, the emote menu + recents, multichat, live status. it also runs the full pipeline against real heatsync.org responses (an end-to-end fixture) and fuzzes every entry point with malformed input, so a wrong-shaped server response or ws frame can't crash the client. no chatterino needed, just `lua5.4`:

```
lua5.4 test/harness.lua              # full suite
TIER=t1 lua5.4 test/harness-degrade.lua   # stable-build degradation
TIER=t0 lua5.4 test/harness-degrade.lua   # old-build degradation
```

the sandbox mirror strips `os` (chatterino exposes none) so the harness also catches any `os.*` use that would abort load on the real client.

## license

MIT
