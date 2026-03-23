---
sidebar_position: 4
---

# Performance

A single audibility query costs almost nothing. A query loop running 40 listeners every 0.1 seconds, each querying against 60 active emissions in a dense map — that adds up.

This page is about understanding where the cost comes from and how to control it.

---

## Where the Time Goes

Every `QueryPosition` call does some subset of these things:

**1. Iterate active emissions** — `SoundBuffer.IterateNear` builds a snapshot of all active emissions within `MAX_QUERY_RADIUS` (500 studs). This is O(n) over active emissions, with a squared-distance pre-filter to skip obviously out-of-range emissions cheaply. For 128 active emissions the iteration is negligible.

**2. Distance falloff** — `ComputeDistanceFalloff` is three multiplies and two adds per emission. Free.

**3. Occlusion check** — this is the dominant cost. `ComputeOcclusion` in Full accuracy fires up to 6 raycasts plus 6 thickness probes (12 raycasts total) per emission. In Simple accuracy it fires 1. In Skip it fires 0.

**4. Cache lookup** — the occlusion cache is checked before each raycast. A cache hit returns immediately with no raycasts fired. Cache hits are the norm for stationary or slow-moving listeners.

**5. Result sort** — `QueryPosition` sorts all results by effective intensity before returning. At realistic emission counts (< 30 in range of any listener) this is negligible.

---

## The Occlusion Cache

The most impactful single optimization in Resonix is the cache. Occlusion results are stored per `(emissionId, quantizedListenerPosition)` with a 0.15-second TTL. If the same listener queries the same emission from approximately the same position within 0.15 seconds, the raycast is skipped entirely.

The listener position is quantized to a 1.5-stud grid before being used as the cache key. This means a listener moving slowly — walking between cover, adjusting position — consistently hits the cache rather than generating a new raycast every tick.

For systems polling every 0.1 seconds with 30 listeners in a typical scene, cache hit rates above 90% are normal. The cost of a full query is dominated by the raycasts that miss the cache — typically those from recently-spawned emissions or listeners that just moved significantly.

---

## The Per-Query Raycast Budget

As a safety bound, `QueryPosition` and `IsAudibleAt` each enforce a per-call occlusion budget: `MAX_OCCLUSION_PER_QUERY = 16` (set in `Resonix/init.lua`).

Emissions beyond this budget are evaluated with `Accuracy.Skip` — distance falloff only, no raycast. This means the worst-case raycast count per call is bounded to `16 × 7 = 112` raycasts regardless of how many emissions are active.

In practice, most queries never approach the budget because:
- The distance pre-filter eliminates emissions outside 500 studs
- The `distance >= emission.Radius` check eliminates emissions the listener is already outside
- `Accuracy.Skip` is auto-selected for any emission where the listener is at 50–100% radius and above

If your profiler shows many queries hitting the budget (emissions being forced to Skip more than you'd like), increase `MAX_OCCLUSION_PER_QUERY`. The constant is local to `init.lua`.

---

## Accuracy Tier Distribution

For a typical game with mixed short-range and long-range sounds:

- **Footsteps** (Radius 12–40): Most nearby listeners are within 50% of radius, so Full accuracy. But footsteps are short-range — most listeners are at `distance >= Radius` and get Skip.
- **Gunshots** (Radius 100–350): Nearby listeners get Full; mid-range get Simple; distant get Skip.
- **Explosions** (Radius 280–400): Large radius means more listeners in the Simple tier. But explosions are infrequent and short-lived.

The system naturally spends the most raycast budget on the interactions that are closest and most acoustically relevant. Distant or already-attenuated emissions are cheap.

---

## Scaling Your Perception Loop

The query loop itself is the other half of the equation. Resonix's query cost scales with:

- Active emission count (buffer size, up to 128)
- Number of callers invoking `QueryPosition` per tick
- Listener density in the scene (more listeners near the same emissions = more cache hits shared between them)

A practical setup for a server with 30+ listeners:

```lua
-- Stagger query ticks across listeners so they don't all query on the same frame
local QUERY_INTERVAL = 0.1  -- seconds

for i, listener in ipairs(activeListeners) do
    -- Offset each listener's first tick by its index to spread the load
    task.delay((i / #activeListeners) * QUERY_INTERVAL, function()
        while listener.Active do
            local stimuli = Engine:QueryPosition(listener.Root.Position, 5)
            ProcessStimuli(listener, stimuli)
            task.wait(QUERY_INTERVAL)
        end
    end)
end
```

Staggered ticks mean no single frame handles all queries simultaneously — the cost is spread evenly across the interval.

---

## Emission Lifecycle

Short-duration emissions expire automatically after `Duration + 0.6s`. Long-duration ambient sounds should be cancelled explicitly when their source stops:

```lua
local id = Engine:EmitPreset("VendingMachine", position, source)

source.AncestryChanged:Connect(function()
    Engine:Cancel(id)
end)
```

Uncancelled long-duration emissions sit in the buffer consuming slots until they naturally expire. If your buffer is unexpectedly full, look for missing `Cancel` calls on persistent sounds.

---

## A Practical Scaling Guide

| Scenario | Recommendation |
|----------|---------------|
| < 20 listeners, low emission density | Default settings; no tuning needed |
| 20–50 listeners, moderate density | Stagger query ticks; watch cache hit rate |
| 50+ listeners or many simultaneous emissions | Raise `MAX_OCCLUSION_PER_QUERY` only if Skip fallback produces noticeably wrong behaviour |
| Dense maps with many thin walls | Full tier fires more raycasts; the budget cap protects frame time |
| Many persistent ambient sounds | Audit for missing `Cancel` calls; keep buffer usage below 80 |
| Server under sustained weapon fire | Cache absorbs most repeated queries; burst periods self-resolve within one TTL cycle (0.15s) |
