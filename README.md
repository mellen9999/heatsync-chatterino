# heatsync chatterino plugin

heatsync inside chatterino: your 5000-slot inventory tab-completes everywhere, and on nightly builds heatsync emotes **render as real images** in chat — yours and every other heatsync user's — plus clickable `>>id` threadlinks, a 🔥 marker on heatsync users, and **kick + youtube chat merged into your twitch tabs**.

no fork, no patched binary. one lua plugin, feature-detected per build:

| your build | what you get |
|---|---|
| nightly (2026+) | everything: inline emote rendering, threadlinks, live sync, tab-complete, commands |
| stable 2.5.5+ | live-synced tab-complete (websocket), `/hsmoments`, `/hslogs` |
| older | tab-complete only |

`/hsstatus` tells you which tier you're on.

## what renders (nightly)

- **your emotes** — anything in your heatsync inventory shows as an image when you post it
- **other chatters' emotes** — a word renders iff the *sender's* inventory has it (same rule as the browser extension). sender sets arrive live over websocket broadcasts and via one batched lookup per ~15 new chatters
- **`>>a1b2c3` threadlinks** — clickable, opens the heatsync.org thread
- twitch emotes, badges, timestamps, replies pass through untouched — messages with no heatsync content are never rebuilt (two hash lookups per word, zero allocation on miss)

- **7TV / BTTV / FFZ you searched** — a niche emote from `/hsfind` or tab-complete that chatterino didn't load renders inline (chatterino-active ones are already emote elements, so no double-render — the plugin only fills the gaps)
- **kick + youtube emotes** in merged multichat — kick's `[emote:id:name]` tokens and youtube's shortcode emotes render as images

known limits: zero-width overlay emotes render as normal images; username paints don't render (no plugin api for it — not faked with colored text).

## multichat — kick + youtube in your twitch tab

`/hsmulti kick:<slug>` or `/hsmulti yt:<handle>` inside a twitch channel tab merges that platform's **live chat** into the tab, tagged `[K]` / `[Y]`. heatsync already ingests kick + youtube chat; the plugin pulls it over the same anonymous websocket and injects it client-side. re-subscribes on reconnect, dedups by message id, and remembers your links across restarts. (youtube needs the channel to be live right now.)

chatterino has no native kick/youtube — this makes heatsync the cross-platform chat layer *inside* it.

## live sync

add an emote on heatsync.org → usable in chatterino within a second (websocket push + debounced re-fetch). the socket is anonymous, reconnects with jittered backoff capped at 60s, heartbeats every 25s, and recycles itself if the server goes quiet. a 15-minute full re-fetch reconciles anything a dropped socket missed.

## the 🔥 marker

heatsync users get a 🔥 before their name in any chat (yours too), so they're identifiable even on plain-text lines. `/hsflame off` turns it off. shows once we've seen someone post heatsync content (no lookup storm on silent chat).

## commands

| command | what |
|---|---|
| `<tab>` | own inventory first (usage-weighted), then 7TV/BTTV/FFZ (one search, popularity-ranked) |
| `/hsfind <query>` | **visual emote picker** — inventory + 7tv/bttv/ffz shown as images; click one to insert it |
| `/hsmulti kick:<slug>` \| `yt:<handle>` \| `off` \| `auto on\|off` | merge kick/youtube chat into this tab; `auto` links a stream's platforms automatically |
| `/hshot` | hottest live streams right now (cross-platform, heat-ranked); click a twitch one to open it |
| `/hswhois <user>` | heatsync profile card for any streamer (heat, followers, live, posts) |
| `/hsarchive on\|off` | opt-in: relay the public twitch chat you view into heatsync's archive (the corpus) |
| `/hsblock <name>` \| `/hsunblock` \| `/hsblocklist` | locally hide an emote (render + tab-complete) |
| `/hsflame on\|off` | toggle the 🔥 heatsync-user marker |
| `/hsbadges on\|off` | show chatterino global badges on chatters (opt-in) |
| `/hsmoments [hours]` | top live chat moments, clickable permalinks |
| `/hslogs <user> [channel]` | chatter stats (messages, channels, active days) + archive link |
| `/hsrefresh` · `/hsemotes` · `/hsstatus` · `/hsclear` · `/hsdump` | inventory refetch · counts · status · clear caches · element dump |

leading `:` is optional — `:pog` and `pog` both match.

`/hsblock` is **local-only**: the plugin connects anonymously, so a block can't sync to your heatsync account (use the website/extension for that). it matches how heatsync models blocks anyway — a viewer-side render preference.

## what a plugin can't do (vs the browser extension)

the extension rewrites twitch.tv's page, so it can add right-click menus, paints, panels, overlays. a chatterino plugin only has chat commands + tab-completion + message building — **no context menus, no settings ui, no username paints, no server-synced blocks**. those are fork-only, and this is deliberately not a fork.

## install

1. open the chatterino plugins folder. linux: `~/.local/share/chatterino/Plugins/`. windows: `%APPDATA%\Chatterino2\Plugins\`. macos: `~/Library/Application Support/chatterino/Plugins/`.
2. clone or unzip this repo into a subfolder named `heatsync`:
   ```
   Plugins/
     heatsync/
       info.json
       init.lua
       *.lua
   ```
3. restart chatterino. settings → plugins → enable plugin support → enable **heatsync** (requires the **Network** permission).

## permissions & privacy

| permission | why |
|---|---|
| `Network` | public read-only heatsync.org endpoints (`/api/profile`, `/api/users/<id>/emotes`, `/api/users/emotes/batch`, `/api/emote-search`, `/api/moments`) + one anonymous websocket for live sync. no auth tokens ever leave chatterino, no writes, nothing sent about you beyond the twitch login of the selected account. |

## architecture

small single-purpose modules: `caps` (feature detection), `net` (http/json/timers), `inventory` (own emotes), `seventv` (search cache), `senders` (other chatters' sets), `ws` (socket lifecycle), `render` (hook → rebuild → replace), `commands`. every hook is pcall-guarded; api absence degrades a tier instead of erroring. when chatterino lands first-class plugin emote providers ([#4999](https://github.com/Chatterino/chatterino2/discussions/4999)), only `render.lua` needs replacing.

## license

MIT
