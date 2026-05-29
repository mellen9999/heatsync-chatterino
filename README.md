# heatsync chatterino plugin

your 5000-slot heatsync emote inventory, tab-completable from chatterino.

type `:pog` → suggests `PogChamp` if it's in your inventory. send the message — any other heatsync-extension user in chat sees it rendered. chatterino itself shows the literal name (custom-emote image injection is outside the plugin api surface).

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
| `<tab>` after typing 1+ chars | suggests heatsync emotes matching the prefix (additive — does not hide twitch / 7tv suggestions) |
| `/hsrefresh` | re-fetches your inventory from heatsync.org |
| `/hsemotes` | prints the current loaded-inventory count |

leading `:` is optional — `:pog` and `pog` both prefix-match.

## permissions

| permission | why |
|---|---|
| `Network` | fetch `heatsync.org/api/profile/<your-login>` + `heatsync.org/api/users/<your-id>/emotes`. both endpoints are public + read-only. no auth tokens, no writes. |

## license

MIT
