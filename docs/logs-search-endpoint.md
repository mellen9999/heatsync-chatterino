# chat-archive search — integration + the one remaining perf gap

status: **wired** (`/hschat` in the plugin) against an endpoint that **already
exists** server-side. this doc corrects an earlier draft that proposed building
a new endpoint — it was based on incomplete probing (`/api/logs/search` 404,
`/api/search` = posts). the real chat-archive json search is **`/api/archive/search`**
(heatsync repo, `server/routes/archive.ts`).

## the endpoint (already in prod)

```
GET /api/archive/search?q=<text>[&username=][&channel=][&platform=][&from=][&to=][&cursor=][&limit=]
→ { results: [{ id, platform, channel, username, display_name, message,
                message_id, timestamp(ISO), emote_refs, badges, reply_to_id }],
    next_cursor }
```

- FTS: `search_vector @@ websearch_to_tsquery('english', q)`, GIN-indexed
  (migration 196, shipped to prod 2026-07-04).
- bounded: 10s statement timeout → **503** `search took too long — narrow the
  query`. keyset paging via `cursor`. `limit` cap 100.
- opt-out aware: delisted channels + hidden chatters excluded.
- guards: rejects bot UAs (`curl/`, `wget`, `bot`, …) with 429; 30 req/min/IP.
  (the plugin's chatterino UA passes.)

## how the plugin uses it (`/hschat`)

`/hschat <query> [@user] [#channel]` — `@user`/`#channel` narrow, the rest is the
query; a bare query scopes to the current tab. results deep-link to
`/logs/<platform>/<channel>/<YYYY-MM-DD>?m=<message_id>` (date = first 10 chars
of the ISO timestamp — no `os.date`, the sandbox has none). a 503/failure is
caught and surfaced as "narrow it with @user or #channel".

## measured perf envelope (prod, 2026-07-08)

| query shape | latency |
|---|---|
| `username=` scoped (any term) | **~0.16s** |
| rare term, global | **~0.16s** |
| `channel=` + date window | ~2.2s |
| mid-freq term + `channel=` | ~4s |
| **common term, global or channel-only** | **>10s → 503** |

so `/hschat` is instant for the dominant use ("where did @user say X", rare
terms) and degrades honestly on broad common words.

## the one remaining server gap (NOT plugin-side)

broad **common-term** FTS across the ~40M-row partitioned corpus still 503s —
`ts_rank` over a huge match set can't be served cheaply by the GIN + timestamp
btree alone. this is a DB-perf problem (candidate: drop `ts_rank` for common
terms, per-channel+time composite indexing, or require a selective filter), and
it already has a dedicated worktree (`heatsync-logsperf`). it needs prod
`EXPLAIN ANALYZE` + measurement — do not rush it blind. the plugin feature does
**not** block on it: narrowed search is the common path and works today.
