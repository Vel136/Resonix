--[=[
	@class ResonixNet

	Full-stack network middleware for Resonix.

	ResonixNet wraps a [Resonix] engine and a `PresetRegistry` to handle
	emission replication, server-side authority, and client-side state
	reconstruction over a single `RemoteEvent`.

	`ResonixNet.new()` is environment-aware: it returns a server handle when
	called on the server and a client handle when called on the client. Both
	share the same `PresetRegistry`.

	**Preset registration order matters.** Fire payloads carry only a 2-byte
	hash assigned by registration position. Register presets in the same order
	on both sides by requiring a shared `ModuleScript`.

	```lua
	-- SharedPresets.lua — required by both server and client
	local Resonix = require(ReplicatedStorage.Resonix)
	local Engine  = Resonix.new()

	Engine:RegisterPreset("Helicopter_Approach", {
	    Intensity = 75, Radius = 500, Duration = 10.0,
	    Frequency = Resonix.Frequency.Low,
	    DefaultTag = "Helicopter_Approach",
	})

	return Engine
	```

	```lua
	-- Server
	local ResonixNet = require(ReplicatedStorage.Resonix.ResonixNet)
	local Engine     = require(SharedPresets)

	local Net = ResonixNet.new(Engine, ResonixNet.PresetRegistry, {
	    Mode               = "ClientAuthoritative",
	    TokensPerSecond    = 20,
	    BurstLimit         = 40,
	    MaxConcurrentEmits = 12,
	    MaxOriginTolerance = 15,
	})

	Net.OnEmitRejected:Connect(function(player, reason)
	    warn(player.Name, "rejected:", reason)
	end)
	```

	```lua
	-- Client
	local ResonixNet = require(ReplicatedStorage.Resonix.ResonixNet)
	local Engine     = require(SharedPresets)

	local Net = ResonixNet.new(Engine, ResonixNet.PresetRegistry)
	Net:Fire("Gunshot_Rifle", character.HumanoidRootPart.Position)
	```
]=]
local ResonixNet = {}

-- ─── Re-exports ───────────────────────────────────────────────────────────────

--[=[
	@prop PresetRegistry PresetRegistry
	@within ResonixNet

	The `PresetRegistry` class, re-exported for convenience. Pass
	`ResonixNet.PresetRegistry` as the second argument to `ResonixNet.new()`.
]=]

-- ─── Factory ─────────────────────────────────────────────────────────────────

--[=[
	Creates a new ResonixNet handle for the current environment.

	Returns a server handle when called on the server and a client handle when
	called on the client. Both share the same `PresetRegistry` instance.

	**NetworkConfig fields (all optional):**

	| Field | Type | Default | Description |
	|-------|------|---------|-------------|
	| `Mode` | `string` | `"ClientAuthoritative"` | Authority mode. See [Authority Modes](#authority-modes). |
	| `TokensPerSecond` | `number` | `20` | Sustained emission rate per player (token bucket). |
	| `BurstLimit` | `number` | `40` | Burst cap — allows rapid back-to-back emissions up to this count. |
	| `MaxConcurrentEmits` | `number` | `12` | Maximum active emissions per player at one time. |
	| `MaxOriginTolerance` | `number` | `15` | Max studs between client-reported and server-validated fire origin. |
	| `LatencyBuffer` | `number` | `0` | Fixed client-side delay in seconds applied when reconstructing emissions. `0` = auto half-RTT. |
	| `ClockSyncRate` | `number` | `2` | How aggressively the client corrects emission expiry timestamps toward the server clock. |
	| `ReplicateState` | `boolean` | `true` | Whether the server sends full state batches for late-join sync. |

	@param resonix Resonix -- The Resonix engine instance to wrap.
	@param presetRegistry PresetRegistry -- Shared preset registry (use `ResonixNet.PresetRegistry`).
	@param networkConfig { Mode: string?, TokensPerSecond: number?, BurstLimit: number?, MaxConcurrentEmits: number?, MaxOriginTolerance: number?, LatencyBuffer: number?, ClockSyncRate: number?, ReplicateState: boolean? }? -- Optional network configuration.
	@return ResonixNet
]=]
function ResonixNet.new(resonix: any, presetRegistry: any, networkConfig: any?): ResonixNet end

-- ─── Server API ──────────────────────────────────────────────────────────────

--[=[
	@server
	Fired when a client emission request fails any of the five server-side
	validation checks.

	The `reason` string identifies which check failed:
	- `"NotInGame"` — player not fully in session
	- `"SessionClosed"` — session not open or concurrent cap exceeded
	- `"OriginTolerance"` — fire position too far from character
	- `"UnknownPreset"` — hash did not match any registered preset
	- `"RateLimit"` — token bucket exhausted

	```lua
	Net.OnEmitRejected:Connect(function(player, reason)
	    warn(player.Name, "emission rejected:", reason)
	end)
	```

	@prop OnEmitRejected Signal<Player, string>
	@within ResonixNet
]=]

--[=[
	@server
	Fired when a client emission request passes all validation checks and is
	committed to the server buffer.

	@prop OnEmitAccepted Signal<Player, string, Vector3, number>
	@within ResonixNet
]=]

-- ─── Client API ──────────────────────────────────────────────────────────────

--[=[
	@client
	Fired when the client receives a replicated emission from the server.

	@prop OnEmitReceived Signal<number, string, Vector3>
	@within ResonixNet
]=]

--[=[
	@client
	Fired when the client receives a cancellation for a previously replicated
	emission.

	@prop OnCancelReceived Signal<number>
	@within ResonixNet
]=]

-- ─── Methods ─────────────────────────────────────────────────────────────────

--[=[
	Emits a sound.

	**On the server** (ServerAuthority or SharedAuthority mode): emits
	immediately on the server buffer and replicates to all clients. Returns
	the server emission ID (a `number`).

	**On the client** (ClientAuthoritative or SharedAuthority mode): encodes
	the request as a compact binary payload and sends it to the server for
	validation. The server emits and replicates if the request passes all
	checks. No return value — the client does not know the server emission ID.

	No-op in `ServerAuthority` mode when called on the client.

	```lua
	-- Server (ServerAuthority or SharedAuthority)
	local emissionId = Net:Fire("Gunshot_Rifle", npcRoot.Position, npcRoot)

	-- Client (ClientAuthoritative or SharedAuthority)
	Net:Fire("Gunshot_Rifle", character.HumanoidRootPart.Position)
	```

	@param presetKey string -- Key of a registered preset.
	@param position Vector3 -- World-space origin of the sound.
	@param source Instance? -- (Server only) Instance excluded from occlusion raycasts.
	@return number -- (Server only) Server emission ID. Returns 0 on error.
]=]
function ResonixNet:Fire(presetKey: string, position: Vector3, source: Instance?): number end

--[=[
	Destroys the handle, disconnects all event connections, and releases all
	internal resources.

	Idempotent — safe to call twice.
]=]
function ResonixNet:Destroy() end

return ResonixNet
