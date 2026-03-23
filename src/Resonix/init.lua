--!native
--!optimize 2
--!strict

--[[
	Resonix
	
	The public API surface of the acoustic simulation engine.
	This is the ONLY module external systems interact with.
]]

local HttpService = game:GetService("HttpService")

local SoundTypes      = require(script.SoundTypes)
local SoundBuffer     = require(script.SoundBuffer)
local SoundPropagator = require(script.SoundPropagator)

type SoundEmission  = SoundTypes.SoundEmission
type SoundStimulus  = SoundTypes.SoundStimulus
type EmissionPreset = SoundTypes.EmissionPreset
type QueryResult    = SoundTypes.QueryResult

-- ─── Module ──────────────────────────────────────────────────────────────────

local Resonix   = {}
Resonix.__index = Resonix
Resonix.__type  = "Resonix"

-- Re-export enums so callers only need to require Resonix
Resonix.Frequency = SoundTypes.Frequency
Resonix.Preset    = SoundTypes.Preset
Resonix.Accuracy  = SoundPropagator.Accuracy

-- ─── Constants ───────────────────────────────────────────────────────────────

local DECAY_WINDOW = 0.6  -- seconds
local CACHE_TTL = 0.15
local CACHE_POSITION_TOLERANCE = 1.5  -- studs
local CACHE_MAX_ENTRIES = 512
local MAX_QUERY_RADIUS = 500  -- studs

-- Maximum number of emissions that receive occlusion checks (Full or Simple)
-- per QueryPosition / IsAudibleAt call. Emissions beyond this budget are
-- evaluated with Accuracy.Skip (distance falloff only, no raycasting).
-- Bounds worst-case raycast count to MAX_OCCLUSION_PER_QUERY × 7 per call.
local MAX_OCCLUSION_PER_QUERY = 16

-- ─── Built-in Presets ────────────────────────────────────────────────────────

local BUILT_IN_PRESETS: { [string]: EmissionPreset } = {
	-- Weapons
	Gunshot_Pistol = {
		Intensity  = 65,
		Radius     = 100,
		Duration   = 0.05,
		Frequency  = SoundTypes.Frequency.High,
		DefaultTag = "Gunshot_Pistol",
	},
	Gunshot_Rifle = {
		Intensity  = 80,
		Radius     = 200,
		Duration   = 0.05,
		Frequency  = SoundTypes.Frequency.High,
		DefaultTag = "Gunshot_Rifle",
	},
	Gunshot_Sniper = {
		Intensity  = 95,
		Radius     = 350,
		Duration   = 0.05,
		Frequency  = SoundTypes.Frequency.High,
		DefaultTag = "Gunshot_Sniper",
	},
	Gunshot_Shotgun = {
		Intensity  = 78,
		Radius     = 150,
		Duration   = 0.05,
		Frequency  = SoundTypes.Frequency.Mid,
		DefaultTag = "Gunshot_Shotgun",
	},

	-- Movement
	Footstep_Walk = {
		Intensity  = 12,
		Radius     = 25,
		Duration   = 0.05,
		Frequency  = SoundTypes.Frequency.Mid,
		DefaultTag = "Footstep_Walk",
	},
	Footstep_Sprint = {
		Intensity  = 22,
		Radius     = 40,
		Duration   = 0.05,
		Frequency  = SoundTypes.Frequency.Mid,
		DefaultTag = "Footstep_Sprint",
	},
	Footstep_Crouch = {
		Intensity  = 5,
		Radius     = 12,
		Duration   = 0.05,
		Frequency  = SoundTypes.Frequency.Mid,
		DefaultTag = "Footstep_Crouch",
	},

	-- Impacts
	Impact_Bullet_Hard = {
		Intensity  = 30,
		Radius     = 50,
		Duration   = 0.05,
		Frequency  = SoundTypes.Frequency.High,
		DefaultTag = "Impact_Bullet_Hard",
	},
	Impact_Bullet_Soft = {
		Intensity  = 20,
		Radius     = 35,
		Duration   = 0.05,
		Frequency  = SoundTypes.Frequency.Mid,
		DefaultTag = "Impact_Bullet_Soft",
	},

	-- Environment
	VendingMachine = {
		Intensity  = 42,
		Radius     = 65,
		Duration   = 60.0,
		Frequency  = SoundTypes.Frequency.Mid,
		DefaultTag = "VendingMachine",
	},
	PowerNode = {
		Intensity  = 38,
		Radius     = 55,
		Duration   = 25.0,
		Frequency  = SoundTypes.Frequency.Mid,
		DefaultTag = "PowerNode",
	},
	PowerFlip = {
		Intensity  = 70,
		Radius     = 120,
		Duration   = 0.1,
		Frequency  = SoundTypes.Frequency.Low,
		DefaultTag = "PowerFlip",
	},

	-- Explosions
	Explosion_Grenade = {
		Intensity  = 88,
		Radius     = 280,
		Duration   = 0.1,
		Frequency  = SoundTypes.Frequency.Low,
		DefaultTag = "Explosion_Grenade",
	},
	Explosion_Large = {
		Intensity  = 98,
		Radius     = 400,
		Duration   = 0.15,
		Frequency  = SoundTypes.Frequency.Low,
		DefaultTag = "Explosion_Large",
	},
}

-- ─── Types ───────────────────────────────────────────────────────────────────

type OcclusionCacheEntry = {
	Transmission : number,
	Timestamp    : number,
}

export type Resonix = typeof(setmetatable({} :: {
	_buffer       : any,
	_presets      : { [string]: EmissionPreset },
	_cache        : { [string]: OcclusionCacheEntry },
	_cacheCount   : number,
	_destroyed    : boolean,
}, { __index = Resonix }))

-- ─── Constructor ─────────────────────────────────────────────────────────────

function Resonix.new(): Resonix
	local self = setmetatable({} :: any, { __index = Resonix })

	self._buffer     = SoundBuffer.new()
	self._destroyed  = false
	self._cache      = {}
	self._cacheCount = 0

	self._presets = {}
	for key, preset in BUILT_IN_PRESETS do
		self._presets[key] = preset
	end

	return self
end

-- ─── Preset Registration ─────────────────────────────────────────────────────

function Resonix.RegisterPreset(
	self   : Resonix,
	key    : string,
	preset : EmissionPreset
)
	assert(key and key ~= "",        "Resonix.RegisterPreset: key is required")
	assert(preset.Intensity,         "Resonix.RegisterPreset: Intensity is required")
	assert(preset.Radius,            "Resonix.RegisterPreset: Radius is required")
	assert(preset.Duration,          "Resonix.RegisterPreset: Duration is required")
	assert(preset.Frequency,         "Resonix.RegisterPreset: Frequency is required")

	self._presets[key] = preset
end

-- ─── Emission ────────────────────────────────────────────────────────────────

function Resonix.EmitPreset(
	self        : Resonix,
	presetKey   : string,
	position    : Vector3,
	source      : Instance?,
	tagOverride : string?
): string
	local preset = self._presets[presetKey]
	assert(preset, string.format(
		"Resonix.EmitPreset: unknown preset '%s'", presetKey
	))

	return self:Emit({
		Position  = position,
		Intensity = preset.Intensity,
		Radius    = preset.Radius,
		Duration  = preset.Duration,
		Frequency = preset.Frequency,
		Source    = source,
		Tag       = tagOverride or preset.DefaultTag,
		PresetKey = presetKey,
	})
end

function Resonix.Emit(
	self   : Resonix,
	config : {
		Position  : Vector3,
		Intensity : number,
		Radius    : number,
		Duration  : number,
		Frequency : string,
		Source    : Instance?,
		Tag       : string?,
		PresetKey : string?,
	}
): string
	assert(not self._destroyed, "Resonix.Emit: system is destroyed")
	assert(config.Position,  "Resonix.Emit: Position is required")
	assert(config.Intensity, "Resonix.Emit: Intensity is required")
	assert(config.Radius,    "Resonix.Emit: Radius is required")
	assert(config.Duration,  "Resonix.Emit: Duration is required")
	assert(config.Frequency, "Resonix.Emit: Frequency is required")

	local now = os.clock()
	local id  = HttpService:GenerateGUID(false)

	local emission: SoundEmission = {
		Id        = id,
		PresetKey = config.PresetKey,
		Position  = config.Position,
		Source    = config.Source,
		Intensity = math.clamp(config.Intensity, 0, 100),
		Radius    = math.max(config.Radius, 1),
		Duration  = math.max(config.Duration, 0),
		Frequency = config.Frequency,
		EmittedAt = now,
		ExpiresAt = now + config.Duration + DECAY_WINDOW,
		Tag       = config.Tag,
	}

	self._buffer:Store(emission)
	return id
end

function Resonix.Cancel(self: Resonix, emissionId: string): boolean
	local toRemove: { string } = {}
	for key in self._cache do
		if key:sub(1, #emissionId) == emissionId then
			table.insert(toRemove, key)
		end
	end
	for _, key in toRemove do
		self._cache[key] = nil
		self._cacheCount -= 1
	end

	return self._buffer:Cancel(emissionId)
end

-- ─── Query Interface ─────────────────────────────────────────────────────────

function Resonix.QueryPosition(
	self         : Resonix,
	position     : Vector3,
	minIntensity : number,
	excludeList  : { Instance }?
): QueryResult
	assert(not self._destroyed, "Resonix.QueryPosition: system is destroyed")

	local exclude = excludeList or {}
	local results: QueryResult = {}
	local occlusionBudget = MAX_OCCLUSION_PER_QUERY

	for emission in self._buffer:IterateNear(position, MAX_QUERY_RADIUS) do
		local distance = (emission.Position - position).Magnitude
		if distance >= emission.Radius then continue end

		local accuracy = SoundPropagator.RecommendAccuracy(emission, distance)
		if accuracy ~= SoundPropagator.Accuracy.Skip then
			if occlusionBudget > 0 then
				occlusionBudget -= 1
			else
				accuracy = SoundPropagator.Accuracy.Skip
			end
		end
		local transmission = self:_GetCachedOcclusion(emission, position, accuracy, exclude)
		local postFalloff = SoundPropagator.ComputeDistanceFalloff(
			emission.Intensity,
			emission.Radius,
			distance
		)

		local effectiveIntensity = postFalloff * transmission

		if effectiveIntensity >= minIntensity then
			table.insert(results, {
				Emission           = emission,
				EffectiveIntensity = effectiveIntensity,
				Direction          = (emission.Position - position).Unit,
				Distance           = distance,
				OcclusionFactor    = transmission,
			})
		end
	end

	table.sort(results, function(a, b)
		return a.EffectiveIntensity > b.EffectiveIntensity
	end)

	return results
end

function Resonix.QueryStrongest(
	self         : Resonix,
	position     : Vector3,
	minIntensity : number,
	excludeList  : { Instance }?
): SoundStimulus?
	local results = self:QueryPosition(position, minIntensity, excludeList)
	return results[1]
end

function Resonix.IsAudibleAt(
	self         : Resonix,
	position     : Vector3,
	minIntensity : number,
	excludeList  : { Instance }?
): boolean
	local exclude = excludeList or {}
	local occlusionBudget = MAX_OCCLUSION_PER_QUERY

	for emission in self._buffer:IterateNear(position, MAX_QUERY_RADIUS) do
		local distance = (emission.Position - position).Magnitude
		if distance >= emission.Radius then continue end

		local accuracy = SoundPropagator.RecommendAccuracy(emission, distance)
		if accuracy ~= SoundPropagator.Accuracy.Skip then
			if occlusionBudget > 0 then
				occlusionBudget -= 1
			else
				accuracy = SoundPropagator.Accuracy.Skip
			end
		end
		local transmission = self:_GetCachedOcclusion(emission, position, accuracy, exclude)
		local postFalloff = SoundPropagator.ComputeDistanceFalloff(
			emission.Intensity, emission.Radius, distance
		)

		if postFalloff * transmission >= minIntensity then
			return true
		end
	end

	return false
end

-- ─── Occlusion Cache ─────────────────────────────────────────────────────────

function Resonix._GetCachedOcclusion(
	self        : Resonix,
	emission    : SoundEmission,
	listenerPos : Vector3,
	accuracy    : string,
	excludeList : { Instance }
): number
	if accuracy == SoundPropagator.Accuracy.Skip then
		return 1.0
	end

	local listenerKey = self:_QuantizePosition(listenerPos)
	local cacheKey    = emission.Id .. "|" .. listenerKey

	local cached = self._cache[cacheKey]
	if cached then
		local age = os.clock() - cached.Timestamp
		if age <= CACHE_TTL then
			return cached.Transmission
		end
	end

	local excludes = excludeList
	if emission.Source then
		local withSource = table.clone(excludeList)
		table.insert(withSource, emission.Source)
		excludes = withSource
	end

	local transmission = SoundPropagator.ComputeOcclusion(
		emission.Position,
		listenerPos,
		emission.Frequency,
		excludes,
		accuracy
	)

	if not cached then
		self._cacheCount += 1
		if self._cacheCount >= CACHE_MAX_ENTRIES then
			self:_PruneCache()
		end
	end

	self._cache[cacheKey] = {
		Transmission = transmission,
		Timestamp    = os.clock(),
	}

	return transmission
end

function Resonix._QuantizePosition(self: Resonix, pos: Vector3): string
	local t = CACHE_POSITION_TOLERANCE
	return string.format("%d_%d_%d",
		math.round(pos.X / t),
		math.round(pos.Y / t),
		math.round(pos.Z / t)
	)
end

function Resonix._PruneCache(self: Resonix)
	local now       = os.clock()
	local toRemove: { string } = {}

	for key, entry in self._cache do
		if now - entry.Timestamp > CACHE_TTL then
			table.insert(toRemove, key)
		end
	end

	for _, key in toRemove do
		self._cache[key] = nil
		self._cacheCount -= 1
	end
end

-- ─── Stats and Debug ─────────────────────────────────────────────────────────

function Resonix.GetStats(self: Resonix): { [string]: any }
	return {
		ActiveEmissions = self._buffer:GetCount(),
		CacheEntries    = self._cacheCount,
	}
end

function Resonix.GetActiveEmissions(self: Resonix): { SoundEmission }
	local result: { SoundEmission } = {}

	for emission in self._buffer:IterateNear(Vector3.zero, math.huge) do
		table.insert(result, emission)
	end

	return result
end

-- ─── Lifecycle ───────────────────────────────────────────────────────────────

function Resonix.Destroy(self: Resonix)
	if self._destroyed then return end
	self._destroyed = true

	self._buffer:Destroy()
	table.clear(self._cache)
	self._cacheCount = 0
end

return Resonix