# heatsync chatterino plugin

a single lua plugin (no fork, no patched binary) that brings heatsync into chatterino: inline emote rendering, click-to-insert emote menu, >>threadlinks, kick+youtube multichat, live inventory sync, 🔥 marker, tab-complete from inventory + 7TV/BTTV/FFZ.

## run / test

- no build step. lua 5.4. loads from chatterino's `Plugins/heatsync/` dir.
- `lua5.4 test/harness.lua` — full headless suite (stubs the c2 API, drives real modules)
- `TIER=t1 lua5.4 test/harness-degrade.lua` — stable-build degradation
- `TIER=t0 lua5.4 test/harness-degrade.lua` — old-build degradation
- `./release.sh` — build `dist/heatsync.zip` (suites gate it) · `./release.sh publish` — tag + upload as the latest github release (bump `info.json` first)
- the harness sandbox strips `os.*` (chatterino exposes none) — **never call `os.*`**, it aborts load on the real client. tests catch it.

## non-negotiables

- **not a fork.** only chat commands, tab-completion, message building, and (feature-gated via `caps.menus`) context menus are reachable. no settings UI, no username paints. don't propose features that need a fork.
- **capability-gated.** everything feature-detects at boot via `caps.lua` and degrades one feature at a time. every hook is `pcall`-guarded. a missing API must degrade, never error.
- **privacy invariant (crown jewel).** a word inline-renders iff the *sender's own* heatsync inventory has it — the search/catalog cache must NEVER feed the render path (that's the "lost"-is-a-7tv-cat bug, e3fb9f0). the websocket + search proxy are always anonymous (no auth/cookie/identity). the plugin never broadcasts what you post. see memory `emote-privacy-invariant`.
- **the login is opt-in and token-scoped.** with no token (`account.txt` absent) every feature behaves exactly as before. the token (from `/hslogin` pairing) is sent ONLY as `Authorization: Bearer` on https requests to `https://heatsync.org/api/cli/*` — `net.cli_request` refuses any other host/path, the websocket never carries it, and it is never logged or printed (`net.redact` scrubs every log line + system message; `/hsstatus` shows login/scopes/expiry only). stored in plain text in the plugin's data folder like any chat client's token. all token traffic goes through `account.request`; nothing else may set an Authorization header. no `os.*` means no calendar: expiry maths uses `net.wall_ms()` (server-timestamp anchored), never a guess.
- **`render.lua` is the single chokepoint** — if chatterino ever exposes first-class plugin emote providers, that's the only file that changes.

## defaults (store.lua)

- archive relay — **on** (opt-out), disclosed on boot
- auto-multichat — **on** (opt-out), only where streamer publicly linked accounts
- pinned message (`pin.txt`) — **on** (opt-out), view-only over the anonymous socket; pinning/clearing is the opt-in login (`/hspin clear`, right-click → pin message), never the socket
- moment spikes (`spikes.txt`) — **off** (opt-in), `/hsmoments on|off`
- live status (`live.txt`) — **off** (opt-in), `/hslive on|off`; 🔴/⚫ for kick/yt only (twitch go-live is native), 🎮/📝 game+title lines for kick/yt AND open twitch tabs — one toggle
- badges — **off** (opt-in)
- flame 🔥 — on
- heat bars (`heat.txt`) — **on** (opt-out), `/hsheat on|off`; never a 🔥 on/next to a heat score
- sub flair (`flair-badges.txt`) — **on** (opt-out), `/hsflair on|off`
- name colors (`namecolors.txt`) — **on** (opt-out), `/hscolors on|off`; youtube lines only (twitch never recolored, painted chatters untouched)
- history backfill (`backfill.txt`) — **on** (opt-out), `/hsbackfill on|off`
- mention highlights (`mentions.txt`) — **on** (opt-out), `/hsmentions on|off`; merged kick/yt lines only, local, gated on `caps.highlight`
- community mutes (`mutes.txt`) — **off** (opt-in), `/hsmutes on|off`; collapses (never hides) muted chatters' lines to a placeholder, matching the site's mute; per-channel 10min ttl cache; t2 only; sends only the channel name
- heatsync login (`account.txt`) — **off** (opt-in), `/hslogin` · `/hslogout`; with it: `/hsnote` synced notes (`/api/cli/user-notes`, the same system the extension's card uses), `/hsmute` `/hsunmute` `/hsmutelist` account mutes (collapse via the `mutes` path), `/hsblock` `/hsunblock` also sync by emote hash, account mention rules (word/phrase; regex skipped) on merged lines, `/hsfollow` `/hsunfollow`, pin message. pulled on login + every 5 min (`account_sync`); token auto-renews at <7 days left
- `/hsgif` — explicit command, no toggle (nothing fetched until run); thumbnails only via /api/img, 12 per page
- link previews (`previews.txt`) — **off** (opt-in), `/hspreviews on|off`; first non-image link, 1 per message, thumbnail only via /api/img, 10 new urls/min, failures remembered; t2 + images cap only
- inline images (`images.txt`) — **off** (opt-in), `/hsimages on|off`; only ever loaded through heatsync.org/api/img, never the image host; max 1 per message, 20 new urls/min

## modules

`caps` feature-detect · `net` http/json/timers/datafiles · `inventory` your emotes · `seventv` catalog search + render cache · `senders` other chatters' sets · `recents` learned usage · `picker` clickable grids · `gifs` / `cmd_gifs` /hsgif search + grid · `ws` socket lifecycle · `multichat` kick/yt injection · `live` opt-in stream-state lines (kick/yt live+game/title, twitch game/title) · `pin` heatsync pinned message (view-only) · `lookup` shared batched ttl cache · `heat` / `flair` / `namecolor` batched cosmetic lookups (rendered by `render`, `multichat`) · `cmd_card` /hscard + right-click card · `spike` opt-in moment spikes · `modifiers` emote modifier tokens (tooltip only) · `previews` link previews (embed/resolve + link-preview, drawn by `render`) · `mutes` community-mute lists per channel + your account mutes (collapse done by `render`) · `mention` highlight flag+color for merged lines aimed at you, login + account rules (built in `multichat`) · `images` image-link detection + proxy url + webp size probe (rendered by `render`) · `render` hook→rebuild→replace · `store` persisted toggles + account emote-block hashes · `account` the opt-in login: token file, the one authed request door, rotate, errors · `pairing` /hslogin device-code state machine · `account_sync` pulls mutes/blocks/rules/following · `cmd_account` login + notes/mutes/follow/pin commands · `commands` · `menu` right-click context menu · `init` wiring.

## conventions

- lowercase UI copy + commit messages, no trailing periods on short labels
- conventional commits (feat/fix/refactor/chore/docs), atomic, no AI fingerprints, no Co-Authored-By
- keep code comments matching real behavior (defaults drift — f078e4c/this session fixed stale "opt-in" comments)
