--!native
--!optimize 2
--!strict

--[[
	SoundTypes
	
	All type definitions for the SoundSystem.
	Separated into their own module so every layer can import types
	without creating circular dependencies.
	
	The sound system has zero knowledge of any game system, weapon, or domain logic.
	These types reflect physical acoustic concepts only — intensity, radius,
	frequency, material — not game-mechanical concepts like "gunshot" or "player".
	
	The Tag field is the one exception: it carries external metadata that the
	sound system stores but never reads. External systems use it to classify
	stimuli after querying. The sound system itself is completely indifferent to it.
]]

local SoundTypes = {}

-- ─── Frequency Bands ─────────────────────────────────────────────────────────
--[[
	Three frequency bands determine how aggressively different materials
	absorb a sound. High-frequency sounds (gunshot crack, footstep tap) are
	absorbed far more aggressively by dense materials than low-frequency
	sounds (explosion rumble, bass thump).
	
	This mirrors the physical phenomenon of acoustic absorption — concrete
	that reduces a gunshot to a murmur barely affects the low-frequency
	pressure wave of an explosion.
]]

SoundTypes.Frequency = table.freeze({
	Low  = "low",   -- explosion rumble, bass, engine idle
	Mid  = "mid",   -- voice, most ambient sounds, moderate impacts
	High = "high",  -- gunshot crack, glass break, metal ping, footsteps
})

-- ─── Emission Preset Keys ─────────────────────────────────────────────────────
--[[
	These are the standard emission profiles the system ships with.
	External systems pass these keys to SoundSystem.EmitPreset() instead
	of manually constructing an emission table every time.
	
	New presets can be registered at runtime via SoundSystem.RegisterPreset().
	The system is open for extension without modification.
]]

SoundTypes.Preset = table.freeze({
	-- Weapons
	Gunshot_Pistol      = "Gunshot_Pistol",
	Gunshot_Rifle       = "Gunshot_Rifle",
	Gunshot_Sniper      = "Gunshot_Sniper",
	Gunshot_Shotgun     = "Gunshot_Shotgun",

	-- Movement
	Footstep_Walk       = "Footstep_Walk",
	Footstep_Sprint     = "Footstep_Sprint",
	Footstep_Crouch     = "Footstep_Crouch",

	-- Impacts
	Impact_Bullet_Hard  = "Impact_Bullet_Hard",   -- concrete, metal
	Impact_Bullet_Soft  = "Impact_Bullet_Soft",   -- wood, plastic
	Impact_Bullet_Flesh = "Impact_Bullet_Flesh",

	-- Environment interactions
	VendingMachine      = "VendingMachine",        -- 60s channel
	PowerNode           = "PowerNode",             -- 25s interaction
	PowerFlip           = "PowerFlip",             -- instant large boom

	-- Grenades / explosions
	Explosion_Grenade   = "Explosion_Grenade",
	Explosion_Large     = "Explosion_Large",

	-- Characters
	Ronin_Alert         = "Ronin_Alert",
	Ronin_Footstep      = "Ronin_Footstep",
	Ronin_Attack        = "Ronin_Attack",

	-- Extraction
	Helicopter_Approach = "Helicopter_Approach",   -- long duration, huge radius
	Helicopter_Idle     = "Helicopter_Idle",
})

-- ─── Type Exports ─────────────────────────────────────────────────────────────

--[[
	SoundEmission — describes a sound event as physical acoustic energy.
	
	The sound system stores and propagates these. It never reads Tag.
	External systems read Tag from returned SoundStimulus objects.

	Diffraction: when true, SoundPropagator will attempt to find a diffracted
	path around blocking geometry when the direct path is heavily occluded.
	This adds up to (DIFFRACTION_RAY_COUNT × 2) extra raycasts per occluded
	query — enable only for acoustically important emissions (explosions,
	gunshots) where corner-bleed is meaningful for AI or gameplay systems.
	Has no effect when the direct path is already clear.
]]
export type SoundEmission = {
	-- Identity
	Id          : string,    -- unique ID assigned by Emitter.Emit()
	PresetKey   : string?,   -- which preset was used, if any (informational only)

	-- Physical origin
	Position    : Vector3,   -- world-space origin of the emission
	Source      : Instance?, -- the Instance that produced this sound (excluded from occlusion raycasts)

	-- Acoustic properties
	Intensity   : number,    -- source intensity at origin, 0–100 scale
	Radius      : number,    -- maximum propagation distance in studs
	Duration    : number,    -- physical duration in seconds (0.05 for gunshots, 60 for vending)
	Frequency   : string,    -- "low" | "mid" | "high" — affects material absorption

	-- Lifecycle timestamps (set by Emitter, read by Buffer)
	EmittedAt   : number,    -- os.clock() when emitted
	ExpiresAt   : number,    -- EmittedAt + Duration + DECAY_WINDOW

	-- External metadata — sound system stores but never reads this
	Tag         : string?,   -- "Gunshot_Rifle", "Footstep_Walk", etc. — for external consumers

	-- Propagation options
	Diffraction : boolean?,  -- opt-in: try diffracted paths when direct path is blocked
}

--[[
	SoundStimulus — the result of a propagation query.
	
	Returned by SoundSystem.QueryPosition() and SoundSystem.QueryStrongest().
	Contains both the original emission and the computed physical result
	at the listener's position.
]]
export type SoundStimulus = {
	Emission           : SoundEmission, -- original emission data
	EffectiveIntensity : number,        -- computed intensity at listener position, 0–100
	Direction          : Vector3,       -- unit vector from listener TOWARD source
	Distance           : number,        -- straight-line distance from source to listener
	OcclusionFactor    : number,        -- 0–1, how much geometry is blocking (1 = clear, 0 = blocked)
}

--[[
	EmissionPreset — a template for creating emissions.
	
	Registered via SoundSystem.RegisterPreset(). Used by SoundSystem.EmitPreset()
	so callers don't have to specify every field manually.
]]
export type EmissionPreset = {
	Intensity       : number,   -- source intensity at origin
	Radius          : number,   -- maximum propagation distance
	Duration        : number,   -- physical duration in seconds
	Frequency       : string,   -- "low" | "mid" | "high"
	DefaultTag      : string?,  -- default Tag value when using this preset
	Diffraction     : boolean?, -- whether emissions from this preset use diffraction by default
}

--[[
	QueryResult — structured return from QueryPosition.
	Sorted descending by EffectiveIntensity (strongest first).
]]
export type QueryResult = { SoundStimulus }

return SoundTypes