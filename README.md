# heatsync chatterino plugin

heatsync inside chatterino. your emote inventory tab-completes everywhere and — on a render-capable build — heatsync emotes **render as real images** in chat (yours and every other heatsync user's), you get a **click-to-insert emote menu**, you can **browse any chatter's emotes** and **search heatsync's post + chat-log archive** (heatsync archives the channels you watch itself, `/hschat` reads it back) without leaving chat, plus clickable `>>id` threadlinks, a 🔥 marker on heatsync users, heat bars and sub-flair badges on chatters, a **user card** (`/hscard`), and **kick + youtube chat merged into your twitch tabs** (with their recent history).

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

known limits: zero-width overlay emotes render as normal inline images; modifier tokens (`w!`, `h!`, `ffzX`, `c!#ff8700`, chains like `w!h!ffzX`) are recognised next to a heatsync emote and named in its tooltip (`· wide · flipH`), but the image itself isn't transformed — a plugin can't — and the token word is hidden rather than printed as stray text; username paints don't render (there's no plugin API for them, and they're not faked with colored text — a painted chatter just keeps the default color).

## the emote menu

`/hsemotes` opens a clickable grid of **your** inventory — recently-used first, then usage-ranked — click any emote to insert it. it's the native-emote-menu experience a plugin can reach without a fork.

- `/hsemotes` — page one
- `/hsemotes 2` — next page
- `/hsemotes <query>` — filter your inventory to matching names

recents are learned from the emotes you actually send (the only usage signal a plugin can observe — chatterino handles click-inserts itself with no callback) and persist across restarts.

## gifs

`/hsgif <query>` shows heatsync's gif library as a clickable grid (12 per page); click one and its url drops into your input, ready to send — the same thing the extension's gif tab does. `/hsgif` alone shows the top gifs, `/hsgif <query> 2` the next page (up to page 4; the server has no offset, so a later page re-asks for more). the library is heatsync's own — searching never reaches giphy or tenor — and the tiles are still frames loaded through heatsync's image proxy (`/api/img`), so the gif host never sees your ip. a cold library says it's still filling up instead of blaming your query. tiles are scaled from an assumed still height, so a source whose stills aren't 200px tall lands proportionally bigger or smaller. on a build without image support you get clickable `[caption]`s instead. nothing is fetched until you run it, so there's no toggle.

## multichat — kick + youtube in your twitch tab

`/hsmulti kick:<slug>` or `/hsmulti yt:<handle>` inside a twitch channel tab merges that platform's **live chat** into the tab, tagged `[K]` / `[Y]`. heatsync already ingests kick + youtube chat; the plugin pulls it over the same anonymous websocket and injects it client-side — re-subscribing on reconnect, replaying what a dropped socket missed, deduping by message id, and remembering your links across restarts. a kick/youtube chatter's own heatsync emotes render inline in their merged lines, same rule as twitch.

`/hsmulti auto` (on by default) merges a stream's kick/youtube chat automatically when you open its twitch tab — but only where that streamer has *publicly linked* their cross-platform accounts on heatsync, so channels that haven't stay quiet. `/hsmulti auto off` to disable, `/hsmulti off` to unlink a tab.

when a source is merged it also loads its last ~50 archived lines (`GET /api/recent/...`), so a fresh tab isn't empty — deduped by id against what the socket delivers, oldest first, once per link per session. kick works by slug; youtube needs the channel's `UC…` id (a typed handle has no archive key, but auto-merge passes the id along). `/hsbackfill off` skips it.

chatterino has no native kick/youtube. this makes heatsync the cross-platform chat layer *inside* it. (youtube chat only exists while the channel is live — a source linked while offline says so and retries every couple of minutes.)

## live status

`/hslive on` surfaces a 🔴 line when a kick or youtube source you've merged goes live, and a ⚫ line when it goes offline — in the twitch tab it's linked to. off by default. twitch go-live and offline are left to chatterino, which shows them natively; the value here is kick/youtube, which it doesn't. the go-live signal rides the same anonymous websocket, scoped to the channels you've actually linked, so it costs nothing when off.

with `/hslive on` a linked kick/youtube source also gets a `🎮 <channel> switched to <game>` line when its game changes (the new title is appended if it changed too) and a `📝 <channel> · <title>` line on a title-only change. an identical repeat update is shown once.

the same two lines also show for **twitch**, in that channel's own open tab — chatterino shows "x is live" natively but not a game or title change, so `🎮 <channel> switched to <game>` and `📝 <channel> · <title>` fill that gap. twitch go-live / offline stay skipped. it needs nothing new: every open twitch tab is already joined to its anonymous room, which is where the server sends the update. `/hslive` is the one toggle for all of these stream-state lines.

## moments

`/hsmoments on` shows a `🔥 moment · <n> msgs/30s, <x>× the usual · <game> · <title>` line when a chat you have open spikes far above its own baseline, linked to the moment on heatsync.org. it shows only for channels open here — a twitch tab, or the twitch tab a kick/youtube source is merged into (tagged `[K]` / `[Y]`) — and at most once per channel every 5 minutes. off by default.

## pinned message

heatsync keeps one pinned message per channel (twitch and kick), shown to every heatsync viewer. here it shows up as a system-style line in the tab: `📌 pinned` · the pinner's name · the message. on twitch, clicking the text jumps to the original message if it's still in scrollback. a kick pin lands in the twitch tab the kick chat is merged into, tagged `[K]`. when the pin is removed you get a `📌 pin cleared` line. on by default; `/hspin off` hides it.

pins are view-only here; pin from heatsync.org or the extension (pinning needs a heatsync login and the plugin's socket is anonymous). it costs nothing extra: the pin rides the room the plugin already joins, plus one public `GET /api/pin` when a tab opens.

## live sync

add an emote on heatsync.org and it's usable in chatterino within a second — a websocket push plus a debounced re-fetch. the socket is anonymous, reconnects with jittered backoff capped at 60s, spreads its reconnect when heatsync deploys, heartbeats every 25s, and recycles itself if the server goes quiet; a periodic full re-fetch reconciles anything a dropped socket missed. other chatters' sets update the same way — when someone changes their inventory only their cached set is re-fetched, and an emote only renders on messages sent while they actually had it.

## right-click

on a build with plugin context menus, right-clicking a chat message adds a `heatsync` submenu: that chatter's emotes, chat logs, and whois. right-click a heatsync emote to block or unblock it locally. older builds just don't get the menu — the commands below do the same.

## heat bars

chatters who have heat on heatsync get a colored bar before their name — the plugin's version of the extension's left-edge heat border: nothing under 5 heat, white → yellow → red as it climbs, and the bar thickens with the tier (`▎ ▍ ▌ ▊`). hover it for the score, posts and replies. it's a single glyph, never an emoji beside a number. scores come from one batched `POST /api/users/heat` per handful of new chatters, cached ~2 minutes, and refresh live from the server's heat push. on by default; `/hsheat off` turns it off.

## sub flair

a heatsync user can pick one twitch sub badge to show off; here it appears as a badge image before their name, hover names the broadcaster. one batched `GET /api/users/flair` per handful of new chatters (twitch badge images only — the same cdn host chatterino already uses). on by default; `/hsflair off` turns it off.

## name colors

a heatsync user's picked name color applies to their name on merged **youtube** lines (the first line from someone new keeps the default color while it's looked up; later ones pick it up). same rule as the extension: twitch names are never recolored (twitch's own color is a paid perk), and a chatter with a heatsync paint is left as-is — paints are gradients a plugin can't draw, and a flat stand-in would be a fake. on by default; `/hscolors off` turns it off.

## mention highlights

a merged `[K]` / `[Y]` line that mentions your twitch login gets chatterino's own mention look (the default highlight row, and it lands in your mentions tab), so a ping from kick or youtube doesn't slip by. the rule is the extension's: your login as a whole word, any case, `@` optional (`mellen` yes, `mellenfans` no), never your own lines, and a kick reply aimed at you. on by default, `/hsmentions off` to stop. purely local — nothing is sent anywhere. limits: chatterino's account api gives the plugin your login only (no display name, no kick/youtube alias names), the plugin can't read a custom highlight color, and the extension's server-side mention rules need a heatsync login the anonymous socket doesn't have. needs a build that exposes the highlight flag; without it the toggle is accepted and does nothing.

## community mutes

`/hsmutes on` collapses the lines of chatters that a channel's heatsync community has muted — the same crowd-sourced list heatsync.org applies when you switch community mutes on there (it asks `GET /api/community-mutes/<channel>?threshold=25`, the site's default threshold; the server publishes the names only, never how many people muted them). a muted chatter's line keeps its timestamp and name and the message becomes `[muted by the community]`; a message's text is dropped from search too, and a mention highlight on it is removed. it collapses rather than hides because that's what heatsync's own mute does (keeps the row, strips the body) and because a plugin can't delete a message. it covers twitch lines and merged `[K]` / `[Y]` lines (a mute scoped to one platform only hits that platform; one with no platform hits all). your own lines are never collapsed.

off by default. the list is cached per channel for 10 minutes (the site's own refresh), a failed fetch is remembered for a minute and keeps the previous list, and until a channel's list arrives nothing is collapsed — it never guesses. only the channel name is sent, never a chatter or a message. needs the render-capable build (it replaces messages); on anything older the toggle is accepted and does nothing.

## inline images

`/hsimages on` shows the image under a chat line whose first link is an https image (`.png .jpg .jpeg .gif .webp .avif`, query string ignored) — twitch lines and merged kick/youtube lines. the link text stays; clicking the image opens the original link. one image per message, scaled down to fit 400×220, never enlarged. off by default: every new image url costs heatsync a moderation scan and they're other people's images in your chat, so at most 20 new urls a minute are fetched and beyond that a link just stays a link. a blocked or oversized image stays a plain link.

the image host is never contacted: the image loads through heatsync (`GET /api/img?url=…`), so your ip never reaches it. the first time a url is seen the plugin reads just the image's header bytes through the same proxy to learn its size, then the line is rebuilt with the image a moment later.

## user card

`/hscard <user>` (or right-click → heatsync → card) prints a chatter's heatsync card in the tab: heat, posts, followers, live, how long they've followed this channel, what heatsync's archive has on them, and their last few lines. the name is a link — click it for chatterino's own usercard. it's one anonymous `POST /api/card`; if that ever comes back unusable it falls back to the plain profile + followage endpoints.

## the 🔥 marker

heatsync users get a 🔥 before their name in any chat, so they're identifiable even on plain-text lines. it appears once we've seen someone post heatsync content (no lookup storm on silent chat), and never on your own messages (you know it's you). `/hsflame off` turns it off.

## commands

| command | what |
|---|---|
| `<tab>` | own inventory first (usage-weighted), then the global catalog (7TV/BTTV/FFZ, popularity-ranked) |
| `/hsemotes [page\|query]` | **your emote menu** — clickable inventory grid, recents-first; page or filter it |
| `/hsfind <query>` | **catalog search** — inventory + 7TV/BTTV/FFZ shown as images; click one to insert |
| `/hsgif [query] [page]` | **gif search** — heatsync's gif library as a grid of stills; click one to insert its url |
| `/hsinv <user> [page]` | **browse anyone's inventory** — a user's heatsync emotes as a click-to-insert grid, paged |
| `/hssearch <query>` | **search heatsync posts** — click a result to open the thread |
| `/hschat <query> [@user] [#channel]` | **search the chat archive** — heatsync's twitch-chat archive; click a line to open it at the exact message. narrow with `@user`/`#channel` (a bare query scopes to the current tab), or the server's `from:` `in:` `has:` `before:` `after:` operators |
| `/hsmulti kick:<slug>` \| `yt:<handle>` \| `off` \| `auto on\|off` | merge kick/youtube chat into this tab; `auto` links a stream's platforms automatically |
| `/hshot [platform] [page]` | hottest live streams right now (cross-platform, heat-ranked); filter by platform, page through; click a twitch one to open it |
| `/hswhois <user>` | heatsync profile card for any streamer (heat, followers, live, posts) |
| `/hscard <user>` | a chatter's card: heat, posts, follows this channel since, archive stats, last lines; the name opens chatterino's usercard |
| `/hsarchive on\|off` | tell heatsync which public twitch channels you watch, so it archives them itself (on by default; `off` to opt out) |
| `/hsblock <name>` \| `/hsunblock` \| `/hsblocklist` | locally hide an emote (render + tab-complete) |
| `/hsflame on\|off` | toggle the 🔥 heatsync-user marker |
| `/hsheat on\|off` | heat bars before chatters' names (on by default) |
| `/hsflair on\|off` | sub-flair badges before chatters' names (on by default) |
| `/hscolors on\|off` | heatsync users' picked name color on merged youtube lines (on by default) |
| `/hsbackfill on\|off` | load a merged kick/youtube source's last ~50 lines on link (on by default) |
| `/hsmentions on\|off` | chatterino's mention highlight on merged kick/youtube lines that mention you (on by default) |
| `/hsmutes on\|off` | collapse the lines of chatters your channel's heatsync community muted to a short placeholder (opt-in) |
| `/hsimages on\|off` | show image links as inline images, loaded through heatsync's proxy (opt-in) |
| `/hsbadges on\|off` | show chatterino global badges on chatters (opt-in) |
| `/hspin on\|off` | the channel's heatsync pinned message as a 📌 line, view-only (on by default) |
| `/hslive on\|off` | 🔴/⚫ go-live + offline lines for your linked kick/youtube sources, and 🎮/📝 game + title switch lines for those and your open twitch tabs (opt-in) |
| `/hsmoments on\|off` | 🔥 line when a chat you have open spikes (opt-in) |
| `/hsmoments [<n>h] [platform] [page]` | top live chat moments, clickable permalinks; `48h` sets the window, a bare number pages, filter by platform |
| `/hslogs <user> [channel]` | chatter stats (messages, channels, active days, top channels) + archive link |
| `/hshelp` | one-screen index of every command, with a note on what this build supports |
| `/hsrefresh` · `/hsstatus` · `/hsclear` · `/hsdump` · `/hstest` | inventory refetch · capability/status report · clear caches · dump last message's elements to the log · post a render self-test |

a leading `:` is optional — `:pog` and `pog` both match. `/hsstatus` also shows multichat's per-tab links and any lines it's had to drop (a tab closed mid-merge), so a merge is legible instead of silent. new to the plugin? `/hshelp`.

`/hsblock` is **local-only**: the plugin connects anonymously, so a block can't sync to your heatsync account (use the website/extension for that). that also matches how heatsync models blocks — a viewer-side render preference, not a server-side filter.

## what a plugin can't do (vs the browser extension)

the extension rewrites twitch.tv's page, so it can add right-click menus, username paints, settings panels, overlays. a chatterino plugin only has chat commands, tab-completion, message building, and (on builds that expose it) a right-click menu — **no settings UI, no username paints, no injecting into chatterino's own emote picker, no server-synced blocks, no pinning or moderation (the plugin's socket is anonymous)**. those need a fork, and this is deliberately not a fork. everything above is what's reachable *without* one, built to the edge of that line.

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
| `Network` | public heatsync.org endpoints (`/api/profile`, `/api/users/<id>/emotes`, `/api/users/emotes/batch`, `/api/emote-search`, `/api/search`, `/api/archive/search`, `/api/moments`, `/api/live/top`, `/api/pin`, `/api/chatter/<...>/stats`, `/api/chatterino-badges`, `/api/users/heat`, `/api/users/flair`, `/api/paints`, `/api/card`, `/api/twitch/followage`, `/api/img` (inline images, opt-in; gif thumbnails), `/api/gifs/search` + `/api/gifs/top` (`/hsgif`), `/api/community-mutes/<channel>` (community mutes, opt-in), `/api/recent/<kick\|youtube>/<channel>`) plus one anonymous websocket for live sync and multichat. |
| `FilesystemRead` / `FilesystemWrite` | remembers your settings, block list, multichat links, and recently-used emotes in the plugin's own data folder. local only. |

**what leaves chatterino:**

- your twitch login (of the selected account) — so the server can sync your emote inventory.
- while `/hsarchive` is **on** (the default, render-capable builds only): which public twitch channel you're watching — just the channel name, at most once per 5 minutes — so heatsync can archive it server-side. `/hsarchive off` stops it. no message text, username, message id, or timestamp is ever sent.
- while heat bars / sub flair are **on** (the default): the twitch logins and ids of chatters in the tabs you have open, in small batches, so heatsync can answer with their heat and flair — the same kind of lookup the emote sets already make. `/hsheat off` and `/hsflair off` stop them. name colors send the youtube channel ids of merged-in chatters the same way (`/hscolors off`).
- while `/hsimages` is **on** (opt-in): an image link in chat is sent to heatsync (`/api/img?url=…`) so heatsync fetches, scans and serves the image — the image host never sees your ip, but heatsync sees the link. `/hsimages off` stops it.
- while `/hsmutes` is **on** (opt-in): the name of each twitch channel you have open is sent to heatsync (`/api/community-mutes/<channel>`) to fetch its muted list — no chatter, message or account. `/hsmutes off` stops it.
- `/hsgif` sends the query you typed to heatsync (`/api/gifs/search`) and loads the stills through its image proxy; only when you run it.
- `/hscard` sends the one login you ask about, and the tab it's in. a merged kick/youtube source's history request sends the source's channel name (`/hsbackfill off` skips it).
- nothing else. no auth tokens (the socket is anonymous), no whispers/DMs, no browsing history, no telemetry.

## architecture

small single-purpose modules: `caps` (feature detection), `net` (http / json / timers / data files), `inventory` (your emotes), `seventv` (catalog search + render cache), `senders` (other chatters' sets), `recents` (learned usage), `img` (image-set builder + CDN allowlist), `picker` (clickable emote / gif grids), `gifs` (gif search + cache), `ws` (socket lifecycle), `multichat` (kick/youtube injection), `live` (opt-in go-live status), `mention` (mention highlights), `pin` (view-only pinned message), `badges` (chatterino badges), `images` (inline image detection, proxy url, size probe), `mutes` (opt-in community-mute lists, collapsed by `render`), `lookup` (the shared batched ttl cache behind `heat` / `flair` / `namecolor` / `mutes`: heat bars, sub-flair badges, youtube name colors), `render` (hook → rebuild → replace), `store` (persisted toggles), and the command layer — `cmdutil` (shared helpers) plus `cmd_emotes` / `cmd_archive` / `cmd_card` / `cmd_multichat` / `cmd_system`, all wired by `init`. every hook is pcall-guarded and every capability is feature-detected, so a missing API degrades one feature instead of erroring. if chatterino ever exposes first-class plugin emote providers, `render.lua` is the only file that needs to change.

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
