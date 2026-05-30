# heatsync chatterino plugin

tab-completes from your 5000-slot heatsync inventory **and** the full 7TV global catalog (popularity-ranked), inside chatterino.

type `:pog` → suggests:

1. `PogChamp` from **your inventory** first
2. `Pog`, `Pogey`, `Poggers`, ... from **7TV global**, ranked by all-time popularity

pick one, send the message. any other heatsync-extension user in chat sees it rendered. chatterino itself shows the literal text (custom emote image injection is outside the plugin api surface).

paired with the [chrome / firefox extension](https://chromewebstore.google.com/detail/heatsync/afadollcanjpemaonbgnkhjddaebjeja).

## install

requires chatterino built with `CHATTERINO_PLUGINS` enabled (nightly builds have it; release builds at the time of writing do not).

1. open the chatterino plugins folder. on linux: `~/.local/share/chatterino/Plugins/`. on windows: `%APPDATA%\Chatterino2\Plugins\`. on macos: `~/Library/Application Support/chatterino/Plugins/`.
2. clone or unzip this repo into a subfolder named `heatsync`. final layout:
   ```
   Plugins/
     heatsync/
       info.json
       init.lua
       README.md
   ```
3. restart chatterino. in settings → plugins, enable **heatsync**. the plugin requires the **Network** permission.

## use

the plugin auto-loads your inventory on boot using the currently selected twitch account. nothing to configure.

| command | what |
|---|---|
| `<tab>` after typing 1+ chars | own inventory first (sorted usage_count desc, alpha tiebreak), then 7TV global (TOP_ALL_TIME desc). additive — does not hide twitch / native suggestions. |
| `/hsrefresh` | re-fetches your inventory from heatsync.org |
| `/hsemotes` | prints loaded inventory count + 7TV query cache size |
| `/hsclear` | clears the local 7TV search cache (rarely needed; cap is 64 queries with FIFO eviction) |

leading `:` is optional — `:pog` and `pog` both match.

## ordering & cache

mirrors the browser extension's spec: own emotes first, then 7TV by `TOP_ALL_TIME` popularity. 7TV results are fetched from heatsync's own `/api/emote-search` proxy (server-side Redis cache + single-flight upstream), and cached locally for ~10 minutes per query.

the completion callback is synchronous, so the **first** keystroke on a fresh query returns own-inventory only and kicks off the 7TV fetch in the background. the **next** keystroke (same query, ~50-500ms later) includes the 7TV block. this matches how browser tab-completions debounce.

7TV search only fires for queries ≥ 2 characters to avoid hammering the proxy on every single keypress.

## permissions

| permission | why |
|---|---|
| `Network` | hits 3 public read-only endpoints on heatsync.org: `/api/profile/<login>`, `/api/users/<id>/emotes`, `/api/emote-search`. no auth tokens, no writes. |

## license

MIT
