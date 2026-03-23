--[=[
	@class SoundTypes

	All type definitions and enum constants for Resonix.

	Separated into their own module so every layer can import types without
	creating circular dependencies. These types reflect physical acoustic
	concepts only — intensity, radius, frequency, material — not game-specific
	domain logic.

	The `Tag` field on [SoundEmission] is the one exception: it carries
	external metadata that the sound system stores but never reads. Callers
	use it to classify stimuli after querying.
]=]
local SoundTypes = {}

-- ─── Frequency ───────────────────────────────────────────────────────────────

--[=[
	@prop Frequency { Low: string, Mid: string, High: string }
	@within SoundTypes

	Frequency band constants. Determines which per-material absorption
	coefficients are applied during occlusion.

	| Value | Typical sounds |
	|-------|---------------|
	| `Low` | Explosion rumble, bass, engine idle |
	| `Mid` | Voice, footsteps, moderate impacts |
	| `High` | Gunshot crack, glass break, metal ping |

	High-frequency sounds are absorbed far more aggressively by dense
	materials (concrete, brick) than low-frequency ones. A concrete wall that
	reduces a gunshot crack to near-silence barely dents the pressure wave
	of an explosion.
]=]

-- ─── Preset Keys ─────────────────────────────────────────────────────────────

--[=[
	@prop Preset { [string]: string }
	@within SoundTypes

	Frozen table of all built-in preset key constants. Use these as arguments
	to [Resonix:EmitPreset] to avoid typos.

	```lua
	Engine:EmitPreset(Resonix.Preset.Gunshot_Rifle, origin, character)
	```

	**Built-in presets:**

	| Key | Intensity | Radius | Frequency |
	|-----|:---------:|:------:|:---------:|
	| `Gunshot_Pistol` | 65 | 100 | High |
	| `Gunshot_Rifle` | 80 | 200 | High |
	| `Gunshot_Sniper` | 95 | 350 | High |
	| `Gunshot_Shotgun` | 78 | 150 | Mid |
	| `Footstep_Walk` | 12 | 25 | Mid |
	| `Footstep_Sprint` | 22 | 40 | Mid |
	| `Footstep_Crouch` | 5 | 12 | Mid |
	| `Impact_Bullet_Hard` | 30 | 50 | High |
	| `Impact_Bullet_Soft` | 20 | 35 | Mid |
	| `VendingMachine` | 42 | 65 | Mid |
	| `PowerNode` | 38 | 55 | Mid |
	| `PowerFlip` | 70 | 120 | Low |
	| `Explosion_Grenade` | 88 | 280 | Low |
	| `Explosion_Large` | 98 | 400 | Low |
]=]

-- ─── Types ───────────────────────────────────────────────────────────────────

--[=[
	@interface SoundEmission
	@within SoundTypes

	Describes a sound event as physical acoustic energy. Stored in [SoundBuffer]
	and returned in [SoundStimulus.Emission].

	The sound system stores `Tag` but never reads it — it is purely for
	external consumers to classify stimuli after querying.

	.Id string -- Unique ID assigned by [Resonix:Emit].
	.PresetKey string? -- Which preset was used, if any.
	.Position Vector3 -- World-space origin of the emission.
	.Source Instance? -- The Instance that produced this sound (excluded from occlusion raycasts).
	.Intensity number -- Source intensity at origin, 0–100 scale.
	.Radius number -- Maximum propagation distance in studs.
	.Duration number -- Physical duration in seconds (0.05 for gunshots, 60 for vending machine).
	.Frequency string -- `"low"` | `"mid"` | `"high"` — affects material absorption.
	.EmittedAt number -- `os.clock()` when emitted.
	.ExpiresAt number -- `EmittedAt + Duration + 0.6` (the 0.6s decay window).
	.Tag string? -- External metadata. `"Gunshot_Rifle"`, `"Footstep_Walk"`, etc.
]=]

--[=[
	@interface SoundStimulus
	@within SoundTypes

	The result of a propagation query at a listener's position. Returned
	by [Resonix:QueryPosition] and [Resonix:QueryStrongest].

	.Emission SoundEmission -- Original emission data.
	.EffectiveIntensity number -- Computed intensity at listener position, 0–100.
	.Direction Vector3 -- Unit vector from listener toward the source.
	.Distance number -- Straight-line distance from source to listener in studs.
	.OcclusionFactor number -- Beer-Lambert transmission factor: 1.0 = clear path, ~0 = heavily blocked.
]=]

--[=[
	@interface EmissionPreset
	@within SoundTypes

	A template for creating emissions. Registered via [Resonix:RegisterPreset]
	and used by [Resonix:EmitPreset].

	.Intensity number -- Source intensity at origin, 0–100 scale.
	.Radius number -- Maximum propagation distance in studs.
	.Duration number -- Physical duration in seconds.
	.Frequency string -- `"low"` | `"mid"` | `"high"`.
	.DefaultTag string? -- Default `Tag` value applied to emissions from this preset.
]=]

--[=[
	@type QueryResult { SoundStimulus }
	@within SoundTypes

	Array of [SoundStimulus] returned by [Resonix:QueryPosition]. Sorted
	descending by `EffectiveIntensity` — index `[1]` is always the loudest.
]=]

return SoundTypes
