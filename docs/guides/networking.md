---
sidebar_position: 3
---

# Networking and Trust

Multiplayer acoustic simulation has the same fundamental problem as any client-authoritative system: the client can lie.

A client could claim it fired a gunshot from anywhere in the map, at any rate, using any preset. Without server-side validation, fabricated sounds would appear in every player's query results — listeners reacting to spoofed positions, rate-of-fire exploits drowning the buffer, cheap exploits that flood the server with ghost emissions.

ResonixNet is Resonix's built-in network middleware. It handles emission replication, server-side authority, and client-side state reconstruction over a single `RemoteEvent`.

---

## The Preset Hash System

The first thing to understand about ResonixNet is what it *doesn't* send over the wire: preset configurations.

A naive approach would have the client send the full emission config — intensity, radius, duration, frequency — with every fire request. An exploiter could trivially modify this to emit a 100-intensity, 500-radius sound from any position.

ResonixNet avoids this entirely. Preset tables are **never sent over the network**. Instead, both server and client register the same presets at startup. Fire requests carry only a 2-byte hash that identifies which pre-registered preset was used.

```lua
-- SharedPresets.lua — required by both server and client
-- Register in the same order on both sides; the hash is assigned by registration position

local Resonix = require(ReplicatedStorage.Resonix)
local Engine  = Resonix.new()

Engine:RegisterPreset("Helicopter_Approach", {
    Intensity  = 75,
    Radius     = 500,
    Duration   = 10.0,
    Frequency  = Resonix.Frequency.Low,
    DefaultTag = "Helicopter_Approach",
})

return Engine
```

The client fires `"Helicopter_Approach"` and sends hash `15`. The server looks up hash `15` in its own registry. There's nothing for the client to forge. An unregistered hash is rejected before any emission is created.

:::danger Registration order
Both server and client must register custom presets in the **same order** with the **same keys**. If they diverge, requests using custom presets will be rejected. Enforce this by requiring the same shared `ModuleScript` on both sides — never register conditionally or in environment-specific order.
:::

---

## What Gets Validated

When a fire request arrives on the server, ResonixNet runs five checks before allowing an emission:

**1. Player in game** — the player object exists and has a parent. Prevents handling events from players mid-disconnect.

**2. Session active / concurrent cap** — the player's session is open and their active emission count is below `MaxConcurrentEmits`. Prevents emission flooding.

**3. Origin tolerance** — the reported fire position is within `MaxOriginTolerance` studs of the player's character root. Catches position spoofing and teleport exploits. Skipped if the character hasn't loaded yet.

**4. Preset hash registered** — the hash resolves to a known preset on the server. Catches unknown or modified preset IDs.

**5. Rate limiter token** — the player has a token available in their per-player bucket. This check is **last and destructive** — it only runs after all non-destructive checks pass, preventing token-drain attacks from bad requests that would be rejected anyway.

Rejection reasons are logged server-side only. The client receives no acknowledgement — silence is the only response. Sending rejection codes would let exploiters probe which checks are active and calibrate their requests.

---

## The Flow

```
Client                                    Server
──────                                    ──────
player fires weapon
Engine:EmitPreset("Gunshot_Rifle", pos)

Net:Fire("Gunshot_Rifle", pos)
→ encode: { presetHash, position }
→ send over single RemoteEvent
                                          ← receive packet
                                          ← validate (5 checks in order)
                                          ← Engine:EmitPreset() — emission lives on server
                                          ← broadcast to all clients via batched outbound buffer

← receive broadcast
← Engine:EmitPreset() locally
← local queries can now detect this emission
```

The server is authoritative on all emissions. Clients get a replicated copy for local queries, indicators, and cosmetic feedback. The server's emission is what matters for gameplay-critical logic.

---

## Setup

**Server:**
```lua
local ResonixNet = require(ReplicatedStorage.Resonix.ResonixNet)

local Net = ResonixNet.new(Engine, {
    Mode                = "ClientAuthoritative",  -- default; clients can emit
    TokensPerSecond     = 20,
    BurstLimit          = 40,
    MaxConcurrentEmits  = 12,
    MaxOriginTolerance  = 15,  -- studs; wider = more lag tolerance
})

-- Optional: react to rejected requests for telemetry
Net.OnEmitRejected:Connect(function(player, reason)
    warn(player.Name, "emission rejected:", reason)
end)
```

**Client:**
```lua
local ResonixNet = require(ReplicatedStorage.Resonix.ResonixNet)

local Net = ResonixNet.new(Engine)

-- Fire a sound event from the client (validated by server before replicating)
Net:Fire("Gunshot_Rifle", character.HumanoidRootPart.Position)
```

---

## Authority Modes

ResonixNet supports three authority modes.

### ClientAuthoritative *(default)*

Clients send fire requests. The server validates each one and replicates approved emissions to all clients. This is the standard model for player weapons.

### ServerAuthority

Only server code may emit sounds. Client fire requests are silently dropped. Use this for server-controlled weapons, environmental hazards, or any emission that must originate from server code only.

```lua
local Net = ResonixNet.new(Engine, {
    Mode = "ServerAuthority",
})

-- Server fires directly; replicates to all clients automatically
Engine:EmitPreset("Gunshot_Rifle", sourceRoot.Position, sourceRoot)
```

### SharedAuthority

Both server and client may emit. Client requests go through the full validation pipeline. Server calls bypass it. Use this when player weapons and server-owned sounds share the same `Engine` instance.

---

## Clock Drift Correction

The server's `os.clock()` and the client's `os.clock()` are independent. Without correction, emission timestamps that look like "expires at 1000.0s" on the server might be interpreted as already-expired on a client whose clock reads 1000.3.

ResonixNet's `DriftCorrector` on the client computes:

```
clockOffset = workspace:GetServerTimeNow() - os.clock()
```

This offset is maintained via exponential smoothing and applied whenever server-clock timestamps are converted to local time. The smoothing rate is bounded so that a single bad ping measurement (jitter spike > 100ms) is dampened to a 2% blend rather than snapping the offset immediately.

---

## Late-Join State Sync

A player who joins while long-duration sounds are already active would otherwise miss them entirely. `LateJoinHandler` sends a full state snapshot on join.

For each active emission, the snapshot includes the original server-clock `EmittedAt` and `ExpiresAt`. The client uses `DriftCorrector` to convert these to local time, computes how much lifetime remains, and reconstructs the emission with the correct remaining duration. Emissions that have already expired by the time the snapshot is processed are discarded.

---

## Tuning `MaxOriginTolerance`

The origin check is a tradeoff. Tighter means harder to exploit but more rejections for players with high ping — on a 150ms connection, a character's position can move several studs between when the client fires and when the server validates.

A reasonable starting point is `15` studs. For competitive games, go as low as `10`. For casual games where false rejections matter more than exploit protection, `20`–`25` is appropriate. Monitor your `OnEmitRejected` signal if you're seeing unexpected rejections from legitimate players.

---

## What ResonixNet Can't Do

ResonixNet validates that emissions used registered presets and came from plausible positions. It doesn't validate that the player had the right tool equipped, that the weapon's cooldown had elapsed, or that the player was alive. Those checks are your responsibility before calling `Net:Fire()`.

It also doesn't prevent a client from displaying custom local sounds that never get replicated. Client-side-only spoofing that doesn't affect server-side state is outside Resonix's scope.
