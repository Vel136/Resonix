<div align="center">

**Sound travels where physics says it should.**

[![Version](https://img.shields.io/badge/version-2.0.0-blue)](https://github.com/Vel136/Resonix/releases)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Discord](https://img.shields.io/badge/Discord-Join-5865F2?logo=discord&logoColor=white)](https://discord.gg/XMYMRKcd3g)

</div>

---

Resonix is an acoustic simulation engine for Roblox. It models how sound travels through 3D space — distance falloff, frequency-dependent absorption through materials, and geometric occlusion — and exposes the result as an audibility query any script can call every tick.

Where most games ask "is the player within X studs of this sound?" and call it done, Resonix computes how much of that sound actually arrives at the listener after travelling through walls, floors, and the air between them.

## Features

- **Two-stage propagation** — inverse-square distance falloff followed by Beer-Lambert occlusion accumulation through geometry
- **Frequency-dependent absorption** — 13 materials with per-band (low/mid/high) coefficients; a gunshot crack absorbs into concrete differently than an explosion's pressure wave
- **Three accuracy tiers** — Full ray-march (≤50% radius), Simple single-cast (50–100%), Skip (distance-only); auto-selected per emission per query
- **Occlusion cache** — 512-entry LRU with 0.15s TTL and 1.5-stud position quantization; eliminates redundant raycasts for stationary listeners
- **Per-query raycast budget** — configurable cap (default 16 checks/call) bounds worst-case frame cost regardless of active emission count
- **Sound buffer** — emissions persist for `Duration + 0.6s` so discrete polling ticks never miss instantaneous events like gunshots
- **14 auto-registered presets** — weapons, footsteps, impacts, environment, and explosions; plus 6 additional preset key constants for custom registration
- **ResonixNet** — full network middleware: binary serialization, rate limiting, origin validation, clock drift correction, and late-join state sync over a single `RemoteEvent`
- **MIT licensed**

## Installation

Drop the `Resonix` folder into `ReplicatedStorage` and require it from your scripts.

```lua
local Resonix = require(game.ReplicatedStorage.Resonix)
```

## Quick Start

```lua
local Resonix = require(ReplicatedStorage.Resonix)

-- Create the engine once per game context
local Engine = Resonix.new()

-- Emit a sound when a player fires
Engine:EmitPreset("Gunshot_Rifle", character.HumanoidRootPart.Position, character)

-- Query audibility at a position (runs every ~0.1s)
local stimuli = Engine:QueryPosition(listenerPos, 5)  -- minIntensity threshold = 5

for _, stimulus in stimuli do
    print(stimulus.Emission.Tag, "from", math.floor(stimulus.Distance), "studs")
    print("Effective intensity:", math.floor(stimulus.EffectiveIntensity))
    print("Direction to source:", stimulus.Direction)
    print("Occlusion factor:", stimulus.OcclusionFactor)  -- 1.0 = clear path, ~0 = heavily blocked
end
```

## Built-in Presets

| Preset | Intensity | Radius | Frequency |
|--------|:---------:|:------:|:---------:|
| Gunshot_Pistol | 65 | 100 | High |
| Gunshot_Rifle | 80 | 200 | High |
| Gunshot_Sniper | 95 | 350 | High |
| Gunshot_Shotgun | 78 | 150 | Mid |
| Footstep_Walk | 12 | 25 | Mid |
| Footstep_Sprint | 22 | 40 | Mid |
| Footstep_Crouch | 5 | 12 | Mid |
| Impact_Bullet_Hard | 30 | 50 | High |
| Impact_Bullet_Soft | 20 | 35 | Mid |
| VendingMachine | 42 | 65 | Mid |
| PowerNode | 38 | 55 | Mid |
| PowerFlip | 70 | 120 | Low |
| Explosion_Grenade | 88 | 280 | Low |
| Explosion_Large | 98 | 400 | Low |

## Documentation

Full documentation at **[vel136.github.io/Resonix](https://vel136.github.io/Resonix/)**

- [Getting Started](https://vel136.github.io/Resonix/docs/intro)
- [How Sound Propagates](https://vel136.github.io/Resonix/docs/guides/physics-features)
- [Networking and Trust](https://vel136.github.io/Resonix/docs/guides/networking)
- [Performance](https://vel136.github.io/Resonix/docs/guides/performance)
- [FAQ](https://vel136.github.io/Resonix/docs/faq)

## Community

- [Discord Server](https://discord.gg/XMYMRKcd3g)
- [Instagram](https://www.instagram.com/vedevelopment/)
- [X / Twitter](https://x.com/vedevelopment_)
- [TikTok](https://www.tiktok.com/@vedevelopment)

## License

MIT License — Copyright © 2026 VeDevelopment
