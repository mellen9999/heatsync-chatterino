# security

## reporting a vulnerability

email **mellen@heatsync.org** with:

- a clear description of the issue
- steps to reproduce
- potential impact
- your preferred contact for follow-up

please don't open a public GitHub issue for security bugs. we'll acknowledge within 48 hours and aim to ship a fix within 7 days for critical issues.

## supported versions

the latest release (`info.json` has its version).

## worth reporting

- your heatsync token (`data/account.txt` in the plugin folder) showing up in a log, a chat line, the websocket, or a request to anything but `https://heatsync.org/api/cli/`
- a chat line or server response that makes the plugin read or write outside its own data folder
- the plugin sending more than the readme's privacy section says it does
- an emote drawn for someone who doesn't own it: a word renders only if the sender's own inventory has it

## scope

the plugin is lua that runs inside chatterino, with just the three permissions in `info.json`. the token is stored as plain text in the plugin's data folder, like any chat client's token, and is revocable with `/hslogout` or at heatsync.org/cli. what leaves chatterino is listed in the readme under privacy.
