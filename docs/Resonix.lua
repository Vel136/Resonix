--[=[
	@class Resonix

	Acoustic simulation engine for Roblox.

	Resonix manages all active sound emissions. Every query runs inverse-square
	distance falloff followed by Beer-Lambert geometric occlusion through world
	geometry, and returns a sorted list of [SoundStimulus] objects at the
	listener's position.

	```lua
	local Resonix = require(ReplicatedStorage.Resonix)

	local Engine = Resonix.new()

	-- Emit a sound when an event occurs
	local id = Engine:EmitPreset("Gunshot_Rifle", character.HumanoidRootPart.Position, character)

	-- Query what is audible at a position
	local stimuli = Engine:QueryPosition(listenerPos, 5)

	for _, stimulus in stimuli do
	    print(stimulus.Emission.Tag, stimulus.EffectiveIntensity)
	end

	-- Cancel a long-duration emission early
	Engine:Cancel(id)

	Engine:Destroy()
	```
]=]
local Resonix = {}

-- ─── Re-exports ───────────────────────────────────────────────────────────────

--[=[
	@prop Frequency { Low: string, Mid: string, High: string }
	@within Resonix

	Re-export of [SoundTypes.Frequency]. Use `Resonix.Frequency.Low`,
	`Resonix.Frequency.Mid`, or `Resonix.Frequency.High` when registering
	custom presets so you only need one require.
]=]

--[=[
	@prop Preset { [string]: string }
	@within Resonix

	Re-export of [SoundTypes.Preset]. A frozen table of all built-in preset
	key constants. Use these as arguments to `:EmitPreset()` to avoid typos.
]=]

--[=[
	@prop Accuracy { Full: string, Simple: string, Skip: string }
	@within Resonix

	Re-export of `SoundPropagator.Accuracy`. Exposed here so callers only
	need one require when passing an explicit accuracy tier to `:QueryPosition()`.
]=]

-- ─── Factory ─────────────────────────────────────────────────────────────────

--[=[
	Creates a new Resonix engine instance. The engine owns the sound buffer,
	the occlusion cache, and all registered presets.

	14 built-in presets (weapons, footsteps, impacts, environment, explosions)
	are registered automatically. [SoundTypes.Preset] also contains additional
	keys (`Ronin_*`, `Helicopter_*`, `Impact_Bullet_Flesh`) as convenient
	constants — register these with your own configs via `:RegisterPreset()`
	before calling `:EmitPreset()` with them.

	```lua
	local Engine = Resonix.new()
	```

	@return Resonix
]=]
function Resonix.new(): Resonix end

-- ─── Preset Registration ─────────────────────────────────────────────────────

--[=[
	Registers a custom emission preset under the given key.

	Once registered, the preset can be used with `:EmitPreset()` and
	`ResonixNet:Fire()`. Both server and client must register custom presets
	in the **same order** when using ResonixNet — the hash is assigned by
	registration position.

	```lua
	Engine:RegisterPreset("Helicopter_Approach", {
	    Intensity  = 75,
	    Radius     = 500,
	    Duration   = 10.0,
	    Frequency  = Resonix.Frequency.Low,
	    DefaultTag = "Helicopter_Approach",
	})
	```

	@param key string -- Unique preset identifier. Used as the argument to `:EmitPreset()`.
	@param preset EmissionPreset -- Preset configuration table.
]=]
function Resonix:RegisterPreset(key: string, preset: EmissionPreset) end

-- ─── Emission ────────────────────────────────────────────────────────────────

--[=[
	Emits a sound using a registered preset.

	Looks up the preset by key, constructs a [SoundEmission], stores it in
	the buffer, and returns the emission's unique ID. Hold onto the ID to
	cancel the emission early via `:Cancel()`.

	The optional `source` argument is an `Instance` excluded from occlusion
	raycasts — pass the character or part that produced the sound so its own
	geometry does not block the sound it just emitted.

	```lua
	-- Simple emit
	Engine:EmitPreset("Gunshot_Rifle", origin, character)

	-- Long-duration emit that can be cancelled
	local id = Engine:EmitPreset("VendingMachine", vendingMachine.Position, vendingMachine)
	-- ... later:
	Engine:Cancel(id)
	```

	@param presetKey string -- Key of a registered preset.
	@param position Vector3 -- World-space origin of the emission.
	@param source Instance? -- Optional Instance excluded from occlusion raycasts.
	@param tagOverride string? -- Overrides the preset's DefaultTag in query results.
	@return string -- Unique emission ID.
]=]
function Resonix:EmitPreset(presetKey: string, position: Vector3, source: Instance?, tagOverride: string?): string end

--[=[
	Emits a sound with a fully specified config table.

	Use this when no preset fits — for one-off sounds with unusual parameters.
	`:EmitPreset()` is preferred for any sound that fires more than once.

	```lua
	local id = Engine:Emit({
	    Position  = origin,
	    Intensity = 55,
	    Radius    = 80,
	    Duration  = 0.1,
	    Frequency = Resonix.Frequency.Mid,
	    Source    = emittingPart,
	    Tag       = "Custom_Sound",
	})
	```

	@param config { Position: Vector3, Intensity: number, Radius: number, Duration: number, Frequency: string, Source: Instance?, Tag: string?, PresetKey: string? }
	@return string -- Unique emission ID.
]=]
function Resonix:Emit(config: { Position: Vector3, Intensity: number, Radius: number, Duration: number, Frequency: string, Source: Instance?, Tag: string?, PresetKey: string? }): string end

--[=[
	Immediately removes an emission from the buffer.

	Any `:QueryPosition()` call after this returns will not include the
	cancelled emission. Occlusion cache entries for this emission are also
	cleared.

	Returns `true` if the emission was found and removed, `false` if it had
	already expired or was never registered.

	@param emissionId string -- The ID returned by `:EmitPreset()` or `:Emit()`.
	@return boolean
]=]
function Resonix:Cancel(emissionId: string): boolean end

-- ─── Query Interface ─────────────────────────────────────────────────────────

--[=[
	Returns every audible emission at `position` with effective intensity at or
	above `minIntensity`.

	Results are sorted descending by `EffectiveIntensity` — index `[1]` is
	always the loudest stimulus. Each result is a [SoundStimulus] containing
	the original emission, computed intensity, direction, distance, and
	occlusion factor.

	The optional `excludeList` lets you exclude specific instances from all
	occlusion raycasts in this query (e.g., the querying character's own model).

	```lua
	local stimuli = Engine:QueryPosition(listenerPos, 5)

	for _, stimulus in stimuli do
	    if stimulus.Emission.Tag == "Gunshot_Rifle" then
	        -- handle gunshot
	    end
	end
	```

	@param position Vector3 -- The listener's world position.
	@param minIntensity number -- Minimum effective intensity threshold (0–100). Stimuli below this are excluded.
	@param excludeList { Instance }? -- Optional instances excluded from occlusion raycasts.
	@return QueryResult -- Array of SoundStimulus, sorted descending by EffectiveIntensity.
]=]
function Resonix:QueryPosition(position: Vector3, minIntensity: number, excludeList: { Instance }?): QueryResult end

--[=[
	Returns the single loudest audible stimulus at `position`, or `nil` if
	nothing at or above `minIntensity` is audible.

	Equivalent to `Engine:QueryPosition(position, minIntensity)[1]` but
	slightly more efficient as it stops after finding the strongest result.

	@param position Vector3
	@param minIntensity number
	@param excludeList { Instance }?
	@return SoundStimulus?
]=]
function Resonix:QueryStrongest(position: Vector3, minIntensity: number, excludeList: { Instance }?): SoundStimulus? end

--[=[
	Returns `true` if at least one emission is audible at `position` with
	effective intensity at or above `minIntensity`.

	More efficient than `:QueryPosition()` when you only need a yes/no answer
	— it short-circuits on the first qualifying emission rather than
	evaluating the full set.

	@param position Vector3
	@param minIntensity number
	@param excludeList { Instance }?
	@return boolean
]=]
function Resonix:IsAudibleAt(position: Vector3, minIntensity: number, excludeList: { Instance }?): boolean end

-- ─── Stats ───────────────────────────────────────────────────────────────────

--[=[
	Returns a snapshot of the engine's current state for profiling.

	| Field | Description |
	|-------|-------------|
	| `ActiveEmissions` | Number of emissions currently in the buffer. |
	| `CacheEntries` | Number of occupied occlusion cache slots. |

	```lua
	local stats = Engine:GetStats()
	print("Active:", stats.ActiveEmissions, "Cache:", stats.CacheEntries)
	```

	@return { ActiveEmissions: number, CacheEntries: number }
]=]
function Resonix:GetStats(): { ActiveEmissions: number, CacheEntries: number } end

--[=[
	Returns all currently active [SoundEmission] objects in the buffer.

	Intended for debug visualisation and tooling. Not for use in hot paths —
	prefer `:QueryPosition()` for runtime queries.

	@return { SoundEmission }
]=]
function Resonix:GetActiveEmissions(): { SoundEmission } end

-- ─── Lifecycle ───────────────────────────────────────────────────────────────

--[=[
	Destroys the engine and releases all resources.

	After this call the instance is inert — the buffer is cleared, the cache
	is cleared, and the background prune task is stopped. Calling any method
	after `Destroy()` will error.

	:::caution
	`Destroy()` is idempotent — calling it twice is safe.
	:::
]=]
function Resonix:Destroy() end

return Resonix
