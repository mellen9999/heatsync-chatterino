-- shared batched lookup cache: a bounded ttl cache + pending queue + single-
-- flight flush. heat / flair / name colors all ask the same question — "what
-- does heatsync know about this key?" — for a stream of keys seen in chat, so
-- the bookkeeping that keeps that from becoming a lookup storm lives here once.
--
--   L = lookup.new{ ttl, fail_ttl, cache_max, pending_max, batch_max, fetch }
--   L:resolve(key)  cached value (false = looked up, nothing there), or nil if
--                   unknown. a stale value is still returned (no flicker) while
--                   a refresh is queued; an unknown key is queued once.
--   L:flush()       drain up to batch_max queued keys into ONE fetch (driven by
--                   a timer in init, never per message)
--   L:put(key, v)   write straight in (a ws push) — only for keys we hold
--   fetch(keys, done) must call done(results) with results[key] = value|false,
--   or done(nil) on any failure (the batch is then retried after fail_ttl)
--   L.on_loaded(key, value) fires per key after a fetch lands
local net = require("net")

local M = {}
local L = {}
L.__index = L

function M.new(opts)
    return setmetatable({
        ttl = opts.ttl,
        fail_ttl = opts.fail_ttl or 30,
        cache_max = opts.cache_max,
        pending_max = opts.pending_max,
        batch_max = opts.batch_max,
        fetch = opts.fetch,
        on_loaded = nil,
        cache = {},   -- key -> { v, ts, used }
        count = 0,
        pending = {}, -- key -> true
        pending_n = 0,
        inflight = false,
        started = 0,
        gen = 0,
    }, L)
end

-- evict the least-recently-used entry. O(n), but only runs when inserting past
-- cache_max — rare — so the hot read path stays a hash lookup.
function L:evict()
    while self.count > self.cache_max do
        local victim, victim_used = nil, nil
        for k, e in pairs(self.cache) do
            if victim_used == nil or e.used < victim_used then victim, victim_used = k, e.used end
        end
        if not victim then break end
        self.cache[victim] = nil
        self.count = self.count - 1
    end
end

-- ts_bias shortens an entry's life (a failed batch is retried after fail_ttl,
-- not a full ttl)
function L:store(key, v, ts_bias)
    local now = net.now()
    if self.cache[key] == nil then self.count = self.count + 1 end
    self.cache[key] = { v = v, ts = now - (ts_bias or 0), used = now }
    self:evict()
end

function L:resolve(key)
    local e = self.cache[key]
    if e then
        e.used = net.now()
        if (net.now() - e.ts) <= self.ttl then return e.v end
    end
    if not self.pending[key] and self.pending_n < self.pending_max then
        self.pending[key] = true
        self.pending_n = self.pending_n + 1
    end
    return e and e.v or nil
end

function L:put(key, v)
    local e = self.cache[key]
    if not e then return end
    e.v = v
    e.ts = net.now()
end

-- a fetch that never calls back (a callback that threw on a hostile payload)
-- must not wedge the queue forever: past this, the next flush supersedes it.
local STUCK_S = 30

function L:flush()
    if self.inflight and (net.now() - self.started) < STUCK_S then return end
    if self.pending_n == 0 then return end
    local keys = {}
    for k in pairs(self.pending) do
        keys[#keys + 1] = k
        self.pending[k] = nil
        self.pending_n = self.pending_n - 1
        if #keys >= self.batch_max then break end
    end
    self.inflight = true
    self.started = net.now()
    self.gen = self.gen + 1
    local gen = self.gen
    local ok = pcall(self.fetch, keys, function(results)
        if gen == self.gen then self.inflight = false end
        if type(results) ~= "table" then
            -- negative-cache briefly so a flaky upstream doesn't hot-loop
            for _, k in ipairs(keys) do
                local e = self.cache[k]
                self:store(k, e and e.v or false, self.ttl - self.fail_ttl)
            end
            return
        end
        for _, k in ipairs(keys) do
            local v = results[k]
            if v == nil then v = false end
            self:store(k, v)
            if self.on_loaded then pcall(self.on_loaded, k, v) end
        end
    end)
    if not ok then self.inflight = false end
end

function L:clear()
    self.cache = {}
    self.count = 0
    self.pending = {}
    self.pending_n = 0
end

function L:stats()
    return self.count, self.pending_n
end

return M
