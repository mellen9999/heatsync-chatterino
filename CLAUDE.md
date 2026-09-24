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
- badges — **off** (opt-in)
- flame 🔥 — on

## modules

`caps` feature-detect · `net` http/json/timers/datafiles · `inventory` your emotes · `seventv` catalog search + render cache · `senders` other chatters' sets · `recents` learned usage · `picker` clickable grids · `ws` socket lifecycle · `multichat` kick/yt injection · `render` hook→rebuild→replace · `store` persisted toggles · `commands` · `menu` right-click context menu · `init` wiring.

## conventions

- lowercase UI copy + commit messages, no trailing periods on short labels
- conventional commits (feat/fix/refactor/chore/docs), atomic, no AI fingerprints, no Co-Authored-By
- keep code comments matching real behavior (defaults drift — f078e4c/this session fixed stale "opt-in" comments)
