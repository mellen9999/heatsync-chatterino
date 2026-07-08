# spec: `/api/logs/search` — json chat-archive search

status: **proposed** (server-side, heatsync repo — not this plugin). unblocks
punchlist #01's remaining half. the plugin already writes the corpus (archive
relay, `render.lua` `maybe_relay`); this lets it read the corpus back.

## why

`/hssearch` today searches heatsync **posts** via `/api/search`. the relayed
**twitch-chat archive** has no json api — only `/logs/search`, which:

- returns HTML (web-only), and
- **503s on broad queries** ("search took too long — try a narrower query").
  observed live 2026-07-08 for a bare `q=hello`.

a chat command can't render HTML and can't hang on a 503. so #01's chat half
needs a fast, bounded json endpoint. everything else (client picker, threadlink
render, anonymous transport) already exists.

## endpoint

```
GET /api/logs/search
```

anonymous (no auth — matches the plugin's anonymous socket + `/api/search`).
edge-cacheable like `/api/emote-search` (same query → same page).

### query params

| param | req | notes |
|---|---|---|
| `q` | yes | search text, ≥2 chars, ≤100 |
| `channel` | no | lowercased twitch channel (narrows the scan — see perf) |
| `username` | no | lowercased sender login |
| `platform` | no | `twitch` \| `kick` \| `youtube`; default all |
| `limit` | no | default 25, **hard cap 50** |
| `before` | no | opaque cursor for paging (last row's `ts`+`id`), newest-first |

### response (200)

mirror `/api/search`'s envelope for client consistency:

```json
{
  "results": [
    {
      "message_id": "abc123",
      "channel": "forsen",
      "username": "someviewer",
      "display_name": "SomeViewer",
      "platform": "twitch",
      "message": "the matched line text",
      "timestamp": 1783545540315,
      "heat": 0
    }
  ],
  "next": "1783545540315:abc123",
  "partial": false
}
```

- `next` — cursor for the next page; omit when exhausted.
- `partial` — `true` if the time budget was hit before a full scan (see perf).
  the client shows "showing partial results — add a channel/user to narrow".

## perf / bulletproof (the 503 is the whole reason this exists)

1. **hard statement timeout → 200 partial, never 503.** on timeout, return the
   rows found so far with `partial:true`. a slow query degrades, it doesn't fail.
2. **bounded scan.** cap rows examined; require `q` to hit an index (trigram/FTS
   on `message`, or narrow by `channel`/`username` first). don't full-scan the
   corpus.
3. **hard `limit` cap 50**, keyset pagination via `before` (no OFFSET on a huge
   table).
4. **validate + lowercase** `channel`/`username`/`platform`; reject `q<2`.
5. **cache** identical queries briefly (redis, like emote-search) so a busy
   channel doesn't re-scan per keystroke-command.

## plugin client wiring (add when the endpoint ships)

the natural home is `/hslogs` — it already carries the user + channel that the
endpoint wants for a fast scan. a trailing quoted phrase turns the archive link
into an inline search:

```
/hslogs <user> [channel] "<query>"   → matching lines, clickable to the archive
/hslogs <user> [channel]             → stats + link (today's behavior, unchanged)
```

sketch (mirrors the existing `linkmsg` + `preview` helpers in `commands.lua`):

```lua
-- inside /hslogs, when a quoted query arg is present:
local url = net.ORIGIN .. "/api/logs/search?q=" .. net.percent_encode(query)
    .. "&username=" .. net.percent_encode(luser)
    .. (chan and ("&channel=" .. net.percent_encode(string.lower(chan))) or "")
    .. "&platform=twitch&limit=8"
net.get_json(url, 8000, function(payload, err)
    local rows = payload and payload.results
    if type(rows) ~= "table" or #rows == 0 then
        sysmsg(ctx, "no archived lines for '" .. query .. "'"); return
    end
    if payload.partial then sysmsg(ctx, "partial results — add a channel to narrow") end
    for _, r in ipairs(rows) do
        -- deep-link to the web archive at this line (server to define the anchor)
        linkmsg(ctx, r.display_name .. " · #" .. r.channel .. ": " .. preview(r.message, 80),
            net.ORIGIN .. "/logs/search?username=" .. net.percent_encode(r.username)
                .. "&channel=" .. net.percent_encode(r.channel) .. "&platform=twitch")
    end
end)
```

no new permissions, no new transport, no privacy change (anonymous GET, results
are local system messages, never feeds the render path — see the privacy
invariant). the endpoint is the only missing piece.
