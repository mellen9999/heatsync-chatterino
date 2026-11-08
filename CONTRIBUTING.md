# contributing

heatsync-chatterino is heatsync inside chatterino: one lua plugin, no fork, no patched binary.

## build and test

there is no build step: lua 5.4, loaded from chatterino's `Plugins/heatsync/`. a headless harness stubs the chatterino api and drives the real modules:

```sh
lua5.4 test/harness.lua
TIER=t1 lua5.4 test/harness-degrade.lua
TIER=t0 lua5.4 test/harness-degrade.lua
```

each ends with `ALL PASS` when it's green. there is no linter or formatter set up: match the file you're editing.

`./release.sh` builds `dist/heatsync.zip` (needs `zip`, and the tests above gate it). `./release.sh publish` tags and uploads, which is the maintainer's job.

## house rules

- never call `os.*`. chatterino exposes none and it aborts the load on the real client; the harness strips `os` too, so tests catch it
- features check what the build can do at boot (`caps.lua`) and degrade one at a time. a missing api must never raise an error
- a word renders only if the sender's own heatsync inventory has it. the catalog is for completion, never rendering

## commits and pull requests

- conventional commits, lowercase, small and atomic: `fix(block): local blocks key by exact emote hash`
- one change per pull request. a behaviour change comes with a harness test
- run all three harness commands before you open it. a version bump in `info.json` is the maintainer's

## licence

MIT. by contributing you agree your work is released under the repo's [LICENSE](LICENSE).

## security

found a vulnerability? don't open a public issue. see [SECURITY.md](SECURITY.md).
