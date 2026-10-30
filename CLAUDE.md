# heatsync chatterino plugin

a single lua plugin (no fork, no patched binary) that brings heatsync into chatterino: inline emote rendering, click-to-insert emote menu, >>threadlinks, kick+youtube multichat, live inventory sync, 🔥 marker, tab-complete from inventory + 7TV/BTTV/FFZ.

## run / test

- no build step. lua 5.4. loads from chatterino's `Plugins/heatsync/` dir.
- `lua5.4 test/harness.lua` — full headless suite (stubs the c2 API, drives real modules)
- `TIER=t1 lua5.4 test/harness-degrade.lua` — stable-build degradation
- `TIER=t0 lua5.4 test/harness-degrade.lua` — old-build degradation
- the harness sandbox strips `os.*` (chatterino exposes none) — **never call `os.*`**, it aborts load on the real client. tests catch it.

## non-negotiables

- **not a fork.** only chat commands, tab-completion, message building, and (feature-gated via `caps.menus`) context menus are reachable. no settings UI, no username paints, no server-synced blocks. don't propose features that need a fork.
- **capability-gated.** everything feature-detects at boot via `caps.lua` and degrades one feature at a time. every hook is `pcall`-guarded. a missing API must degrade, never error.
- **privacy invariant (crown jewel).** a word inline-renders iff the *sender's own* heatsync inventory has it — the search/catalog cache must NEVER feed the render path (that's the "lost"-is-a-7tv-cat bug, e3fb9f0). the socket + search proxy are anonymous (no auth/cookie/identity). the plugin never broadcasts what you post. see memory `emote-privacy-invariant`.
- **`render.lua` is the single chokepoint** — if chatterino ever exposes first-class plugin emote providers, that's the only file that changes.

## defaults (store.lua)

- archive relay — **on** (opt-out), disclosed on boot
- auto-multichat — **on** (opt-out), only where streamer publicly linked accounts
- pinned message (`pin.txt`) — **on** (opt-out), view-only; the socket is anonymous so no pinning from the plugin
- moment spikes (`spikes.txt`) — **off** (opt-in), `/hsmoments on|off`
- live status (`live.txt`) — **off** (opt-in), `/hslive on|off`; 🔴/⚫ for kick/yt only (twitch go-live is native), 🎮/📝 game+title lines for kick/yt AND open twitch tabs — one toggle
- badges — **off** (opt-in)
- flame 🔥 — on
- heat bars (`heat.txt`) — **on** (opt-out), `/hsheat on|off`; never a 🔥 on/next to a heat score
- sub flair (`flair-badges.txt`) — **on** (opt-out), `/hsflair on|off`
- name colors (`namecolors.txt`) — **on** (opt-out), `/hscolors on|off`; youtube lines only (twitch never recolored, painted chatters untouched)
- history backfill (`backfill.txt`) — **on** (opt-out), `/hsbackfill on|off`
- mention highlights (`mentions.txt`) — **on** (opt-out), `/hsmentions on|off`; merged kick/yt lines only, local, gated on `caps.highlight`
- inline images (`images.txt`) — **off** (opt-in), `/hsimages on|off`; only ever loaded through heatsync.org/api/img, never the image host; max 1 per message, 20 new urls/min

## modules

`caps` feature-detect · `net` http/json/timers/datafiles · `inventory` your emotes · `seventv` catalog search + render cache · `senders` other chatters' sets · `recents` learned usage · `picker` clickable grids · `ws` socket lifecycle · `multichat` kick/yt injection · `live` opt-in stream-state lines (kick/yt live+game/title, twitch game/title) · `pin` heatsync pinned message (view-only) · `lookup` shared batched ttl cache · `heat` / `flair` / `namecolor` batched cosmetic lookups (rendered by `render`, `multichat`) · `cmd_card` /hscard + right-click card · `spike` opt-in moment spikes · `modifiers` emote modifier tokens (tooltip only) · `mention` highlight flag+color for merged lines aimed at you (built in `multichat`) · `images` image-link detection + proxy url + webp size probe (rendered by `render`) · `render` hook→rebuild→replace · `store` persisted toggles · `commands` · `menu` right-click context menu · `init` wiring.

## conventions

- lowercase UI copy + commit messages, no trailing periods on short labels
- conventional commits (feat/fix/refactor/chore/docs), atomic, no AI fingerprints, no Co-Authored-By
- keep code comments matching real behavior (defaults drift — f078e4c/this session fixed stale "opt-in" comments)
