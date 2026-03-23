---
sidebar_position: 5
---

# Benchmarks

This page covers how to profile Resonix in your own project and what numbers to look for.

---

## What to Measure

Resonix's cost comes from two sources: `QueryPosition` call duration and raycast count per call. Both are worth tracking separately because they have different causes.

**Query duration** is the wall-clock time of a single `QueryPosition` call. In most games this is under 0.1ms. It rises when:
- Many emissions are active and close to the listener (more falloff calculations)
- Many emissions pass the distance pre-filter and aren't in the cache (more raycasts)
- The occlusion budget is being fully consumed on most calls (high emission density)

**Raycast count** is harder to observe directly, but you can infer it from `GetStats()`:

```lua
-- Call once per frame to monitor state
local stats = Engine:GetStats()
print("Active emissions:", stats.ActiveEmissions)
print("Cache entries:",    stats.CacheEntries)
```

A healthy system has `CacheEntries` growing toward `ActiveEmissions × ListenerCount` over the first few seconds and then stabilizing. If cache entries stay low relative to emission count × listener count, listeners are moving fast enough to miss the cache consistently — consider loosening the position quantization tolerance or increasing TTL.

---

## Profiling a Perception Loop

Wrap your query calls with `os.clock()` to measure per-call cost:

```lua
local function TimedQuery(position, minIntensity)
    local t0 = os.clock()
    local results = Engine:QueryPosition(position, minIntensity)
    local elapsed = os.clock() - t0
    if elapsed > 0.002 then  -- flag anything over 2ms
        warn(string.format("QueryPosition took %.3fms", elapsed * 1000))
    end
    return results
end
```

Run this for a full session under realistic load (many players firing, many listeners querying) and look for outliers. A single call taking over 5ms almost always means the occlusion budget is being fully consumed with no cache coverage.

---

## Emission Density Scenarios

Typical per-query raycast counts under different scenarios, assuming `MAX_OCCLUSION_PER_QUERY = 16`:

| Scenario | Emissions in range | Est. cache hit rate | Est. raycasts/query |
|----------|-----------------:|:-------------------:|--------------------:|
| Idle environment | 0–5 | 80%+ | 0–7 |
| Active firefight (nearby) | 10–20 | 60–80% | 10–30 |
| Heavy sustained fire (dense map) | 20–40 | 40–60% | 30–60 |
| Budget-limited (>16 non-Skip) | 16 capped | varies | ≤112 |

The budget cap at `MAX_OCCLUSION_PER_QUERY = 16` bounds worst-case to `112` raycasts (16 emissions × up to 7 raycasts each in Full accuracy). In practice most of the 16 are in Simple or Full — the actual worst case per real game is typically 40–60 raycasts per call.

---

## Tuning Constants

All performance-related constants are in `Resonix/init.lua`:

| Constant | Default | Effect |
|----------|:-------:|--------|
| `MAX_QUERY_RADIUS` | 500 | Hard spatial pre-filter; reduce for smaller maps |
| `CACHE_TTL` | 0.15s | Increase for slower-moving listeners; decrease if listeners teleport frequently |
| `CACHE_POSITION_TOLERANCE` | 1.5 studs | Quantization grid; increase to raise cache hit rate at the cost of accuracy |
| `CACHE_MAX_ENTRIES` | 512 | Increase if you have many distinct listener × emission combinations |
| `MAX_OCCLUSION_PER_QUERY` | 16 | Increase for more accurate results under high emission load; decrease to reduce worst-case frame spikes |

There is no single correct set of values — the right tuning depends on your map scale, listener count, and emission density. Profile first, then adjust.
