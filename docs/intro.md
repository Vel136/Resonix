---
sidebar_position: 1
---

# Where to Go From Here

Resonix has a few distinct layers. This page is a map.

---

## "I just want to query what sounds are audible at a position."

Start at [Getting Started](./documentation). You need three things: an engine instance, an emit call after each sound event, and a query call in your loop. The main docs page covers all of them and gets you to a working system in under 15 lines.

---

## "My query loop reacts inconsistently — sometimes it detects a sound, sometimes it doesn't."

That's almost always the polling gap problem. [The Polling Gap](./guides/why-bullets-miss) explains why discrete polling ticks miss instantaneous events and how Resonix's sound buffer solves it.

---

## "I want sounds to travel through walls realistically."

[How Sound Propagates](./guides/physics-features) covers the full two-stage model — distance falloff, geometric occlusion, Beer-Lambert absorption, and frequency-dependent material coefficients. It explains when each tier of accuracy is used and what the numbers actually mean.

---

## "I need multiplayer — server authority, client validation, emission replication."

[Networking and Trust](./guides/networking) explains the ResonixNet architecture: authority modes, the preset hash system, the validation pipeline, clock drift correction, and late-join state sync. The API reference is in the `ResonixNet` class docs.

---

## "I need to handle many simultaneous sounds without frame spikes."

[Performance](./guides/performance) covers the per-query raycast budget, the occlusion cache, accuracy tier selection, and how to tune `MAX_OCCLUSION_PER_QUERY` and `CACHE_TTL` for your game's emission density.

---

## Quick Reference

| I want to… | Go to |
|------------|-------|
| Emit a sound | [Getting Started](./documentation) |
| Query audibility at a position | [Getting Started](./documentation) |
| Understand the polling gap | [The Polling Gap](./guides/why-bullets-miss) |
| Understand propagation physics | [How Sound Propagates](./guides/physics-features) |
| Set up multiplayer replication | [Networking and Trust](./guides/networking) |
| Tune performance | [Performance](./guides/performance) |
| Browse the full API | [Resonix](../api/Resonix) |
| Look up built-in presets | [Getting Started](./documentation#built-in-presets) |
| Register a custom preset | [Resonix](../api/Resonix) |
