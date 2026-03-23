---
sidebar_position: 4
---

# FAQ

Answers to the questions that come up most often.

---

## General

**What is Resonix?**

Resonix is an acoustic simulation engine for Roblox. It models how sound travels through 3D space — distance falloff via the inverse square law, and geometric occlusion via Beer-Lambert exponential absorption — and exposes the result as a per-position audibility query. Any caller — a game system, HUD indicator, or script — calls the query to find out what sounds are audible at a given location and how intensely.

---

**Is Resonix free?**

Yes. Resonix is released under the MIT License.

---

**What version is this?**

This documentation covers **Resonix v2.0.0**.

---

**Does Resonix work on the client, the server, or both?**

Both. `Resonix.new()` creates a standalone engine with no environment dependency — it has no RunService connections and no Roblox-specific lifecycle. You create one per game context and call `:EmitPreset()` / `:QueryPosition()` from wherever makes sense. ResonixNet handles the server-client synchronization layer.

---

## Setup

**Where does the Resonix folder go?**

`ReplicatedStorage`. Both client and server need to be able to require it.

---

**Do I need one engine or many?**

One per isolated game system. Most games need exactly one. If you have a server-side system and a separate client-side HUD that should not share state or emission history, you'd create separate engines.

---

**Can I use Resonix without ResonixNet?**

Yes. ResonixNet is completely optional. `Resonix.new()` works standalone — emit from server code, query from server code, and handle your own replication. ResonixNet is only needed when clients need to fire emissions that the server validates and replicates to all players.

---

## Emissions

**What is the `source` parameter in `:EmitPreset()`?**

The `Instance` responsible for the emission — typically the character or part producing the sound. Resonix excludes this instance from occlusion raycasts so the geometry of the emitting object doesn't block the sound it just produced. It's optional but recommended for any emission that originates inside or on a character model.

---

**Why does my 0.05-second gunshot stay in the buffer for 0.65 seconds?**

Every emission gets a `DECAY_WINDOW` of 0.6 seconds added to its configured duration. This ensures that polling loops running at 0.1-second intervals always have at least one clean observation window for instantaneous events. Without the window, a gunshot that fires between two ticks would be missed entirely. See [The Polling Gap](./guides/why-bullets-miss) for the full explanation.

---

**What happens when I cancel an emission?**

`:Cancel(id)` removes the emission from the active buffer immediately. Any `QueryPosition` call after the cancel will not return that emission. The occlusion cache entries for that emission are also invalidated.

---

**The buffer is full (128 emissions). What gets dropped?**

The oldest emission (the one with the earliest `ExpiresAt`) is evicted to make room. Recent events take priority over old ones that are almost expired anyway. If you're regularly hitting the cap, look for long-duration ambient emissions that should have been cancelled but weren't.

---

## Physics

**What does the OcclusionFactor in query results mean?**

It's the transmission coefficient from Beer-Lambert absorption — a value between 0 and 1. `1.0` means a completely clear path; every bit of the falloff intensity reaches the listener. `0.3` means 70% was absorbed by intervening geometry. It never reaches exactly 0 by the mathematics of exponential decay.

---

**Why do explosions penetrate walls better than gunshots?**

Because of frequency-dependent absorption. Low-frequency sounds (explosions) have longer wavelengths that pass through dense materials more easily. High-frequency sounds (gunshot crack) have short wavelengths that are absorbed aggressively by concrete, brick, and similar materials. This emerges directly from the per-material, per-frequency-band coefficient table in `SoundPropagator` — no per-sound special cases.

---

**Can a sound be completely blocked?**

No — by the mathematics of Beer-Lambert exponential decay (`transmission = e^(-absorption)`), the transmission factor approaches but never reaches zero. At extremely high accumulated absorption (≥ 4.0, which is ~1.8% transmission), Resonix returns `0` directly as a practical approximation. In normal gameplay, a sound behind several layers of concrete will be near-inaudible but never exactly zero.

---

## Performance

**How many raycasts does a `QueryPosition` call fire?**

At most `MAX_OCCLUSION_PER_QUERY × 7 = 112`, even with 128 active emissions. Emissions beyond the budget are evaluated with distance falloff only (no raycasting). The cache further reduces this — typical cache hit rates above 90% mean most calls fire far fewer raycasts than the ceiling.

**How do I reduce query cost?**

First, check your cache hit rate via `Engine:GetStats()`. If `CacheEntries` is low relative to your listener × emission count, listeners are moving fast enough to miss the cache — try increasing `CACHE_POSITION_TOLERANCE`. Second, stagger your query calls so they don't all run on the same frame. Third, reduce `MAX_QUERY_RADIUS` if your map is smaller than 500 studs across.

---

## Networking

**Do client and server need to register custom presets in the same order?**

Yes, strictly. Fire payloads carry only a 2-byte hash assigned by registration position. If client and server registration order diverges, every request using a custom preset will be rejected as `UnknownPreset`. Enforce registration order by requiring the same shared `ModuleScript` on both sides.

**Why am I seeing `OriginTolerance` rejections from legitimate players?**

Your `MaxOriginTolerance` is too tight for the ping your players are experiencing. On a 150ms connection, a character can move several studs between when the client fires and when the server validates. Start at `15` studs and increase if legitimate players are being rejected. Check your `OnEmitRejected` signal to see the frequency.

**What does the DriftCorrector do?**

Server and client `os.clock()` values are independent and diverge over time. DriftCorrector computes the offset `workspace:GetServerTimeNow() - os.clock()` from each incoming emission's timestamp and uses exponential smoothing to maintain a stable estimate. This offset converts server-clock timestamps (used in emission `EmittedAt` / `ExpiresAt`) to local time so the client's sound buffer expires emissions at the correct wall-clock moment. Large ping spikes are dampened — a single outlier measurement above 100ms is blended in at only 2% rather than snapping the offset immediately.
