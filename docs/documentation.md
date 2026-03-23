---
sidebar_position: 2
sidebar_label: "Getting Started"
---

# Sound Travels Where Physics Says It Should

Resonix is an acoustic simulation engine for Roblox. It answers one question: *how much of a sound actually reaches a listener?* Not just whether they're in range — how much of it arrives after travelling through walls, floors, and the air between them.

---

## One Folder. One Require.

Drop the `Resonix` folder into `ReplicatedStorage` and require it from your scripts.

```lua
local Resonix = require(ReplicatedStorage.Resonix)
```

---

## Create the Engine

```lua
local Engine = Resonix.new()
```

One engine per game context. It owns the sound buffer, the occlusion cache, and all active emissions. The engine is not a singleton — you can create multiple instances if your game systems need isolated state.

---

## Emit a Sound

Call `:EmitPreset()` whenever a sound event occurs in your game world:

```lua
-- When a player fires a rifle
Engine:EmitPreset("Gunshot_Rifle", character.HumanoidRootPart.Position, character)

-- When a footstep lands
Engine:EmitPreset("Footstep_Sprint", character.HumanoidRootPart.Position, character)

-- When an explosion happens
Engine:EmitPreset("Explosion_Grenade", explosionPosition)
```

The third argument is the `source` — the `Instance` associated with the emission. Pass the character or part so Resonix can exclude it from occlusion raycasts (you don't want the emitting character's own geometry to block the sound it just produced).

`:EmitPreset()` returns a string ID. Hold onto it if you need to cancel the emission early:

```lua
local emissionId = Engine:EmitPreset("VendingMachine", vendingMachine.Position, vendingMachine)

-- Later, when the player stops interacting:
Engine:Cancel(emissionId)
```

---

## Query Audibility

Call `:QueryPosition()` to get every audible emission at a location:

```lua
-- Runs every 0.1s per listener
local stimuli = Engine:QueryPosition(listenerPos, 5)  -- minIntensity = 5

for _, stimulus in stimuli do
    -- stimulus.Emission          — the full SoundEmission record
    -- stimulus.EffectiveIntensity — intensity at the listener after falloff and occlusion (0–100)
    -- stimulus.Direction          — unit vector pointing from listener toward the source
    -- stimulus.Distance           — straight-line distance in studs
    -- stimulus.OcclusionFactor    — transmission factor (1.0 = clear, ~0 = heavily blocked)

    if stimulus.Emission.Tag == "Gunshot_Rifle" then
        -- React to the gunshot
    end
end
```

Results come back sorted by `EffectiveIntensity` descending. Index `[1]` is always the most audible stimulus.

For a quick check without iterating the full result set:

```lua
-- Is anything audible here above threshold?
if Engine:IsAudibleAt(listenerPos, 10) then
    -- something is loud enough to be heard
end

-- What is the loudest thing audible here right now?
local strongest = Engine:QueryStrongest(listenerPos, 5)
if strongest then
    print("Loudest sound:", strongest.Emission.Tag)
end
```

---

## Built-in Presets {#built-in-presets}

Resonix ships 14 presets out of the box:

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

**Intensity** is source loudness on a 0–100 scale. **Radius** is the maximum propagation distance in studs. **Frequency** determines which material absorption coefficients are applied — high-frequency sounds (gunshot crack) are absorbed more aggressively by dense materials than low-frequency ones (explosion rumble).

---

## Register a Custom Preset

```lua
Engine:RegisterPreset("Helicopter_Approach", {
    Intensity  = 75,
    Radius     = 500,
    Duration   = 10.0,    -- seconds the emission persists (plus the 0.6s decay window)
    Frequency  = Resonix.Frequency.Low,
    DefaultTag = "Helicopter_Approach",
})
```

Use `Resonix.Frequency.Low`, `Resonix.Frequency.Mid`, or `Resonix.Frequency.High`.

---

## Emit with Custom Parameters

If a preset doesn't fit, call `:Emit()` directly with a full config table:

```lua
local id = Engine:Emit({
    Position  = origin,
    Intensity = 55,
    Radius    = 80,
    Duration  = 0.1,
    Frequency = Resonix.Frequency.Mid,
    Source    = emittingInstance,   -- optional; excluded from occlusion casts
    Tag       = "Custom_Sound",     -- optional; readable in query results
    PresetKey = "MyCustomPreset",   -- optional; useful for ResonixNet serialization
})
```

---

## Multiplayer

Wrap the engine with `ResonixNet` to replicate emissions across the server and all clients. See [Networking and Trust](./guides/networking) for the full setup.

```lua
-- Server
local Net = ResonixNet.new(Engine, {
    Mode            = "ClientAuthoritative",
    TokensPerSecond = 20,
    BurstLimit      = 40,
})

-- Client
local Net = ResonixNet.new(Engine)
Net:Fire("Gunshot_Rifle", firePosition)
```
