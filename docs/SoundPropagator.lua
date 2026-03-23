--[=[
	@class SoundPropagator

	Pure physics layer for acoustic propagation simulation.

	Every function in this module is pure in the strict sense: no state is
	read or written, no signals are fired, and given the same inputs (except
	for workspace raycasts which depend on geometry), it always produces the
	same outputs. It can be called safely from any context.

	**Two-stage propagation model:**

	Stage 1 — Distance falloff. Sound energy disperses according to the
	inverse square law, normalized to the emission's configured radius.
	O(1), no raycasting.

	Stage 2 — Geometric occlusion. Sound energy is absorbed as it passes
	through solid geometry. Uses Beer-Lambert exponential decay with
	per-material, per-frequency absorption coefficients.

	**Accuracy tiers:**

	| Tier | When used | Raycasts |
	|------|-----------|----------|
	| `Full` | Listener within 50% of radius | Up to 12 (ray march + thickness probes) |
	| `Simple` | Listener 50–100% of radius | 1 |
	| `Skip` | Beyond radius or budget exceeded | 0 |
]=]
local SoundPropagator = {}

-- ─── Accuracy ────────────────────────────────────────────────────────────────

--[=[
	@prop Accuracy { Full: string, Simple: string, Skip: string }
	@within SoundPropagator

	Accuracy tier constants. Pass these to [SoundPropagator.ComputeOcclusion]
	or [SoundPropagator.ComputeEffectiveIntensity] to override the
	auto-selected tier.

	| Value | Meaning |
	|-------|---------|
	| `Full` | Multi-segment ray march with per-material frequency absorption. Most accurate. |
	| `Simple` | Single raycast with fixed conservative attenuation on hit. |
	| `Skip` | No occlusion check — returns `1.0` immediately. |
]=]

-- ─── Stage 1 ─────────────────────────────────────────────────────────────────

--[=[
	Computes the intensity at `distance` from a source after free-space
	propagation, before any geometric occlusion.

	Uses a normalized inverse-square formula:

	```
	intensity(d) = I₀ × (1 - (d / R)²)
	```

	This gives full source intensity at `d = 0` and zero at `d = R`, with a
	smooth physically-motivated curve in between.

	Pure function — no state, no side effects.

	@param sourceIntensity number -- Source intensity at origin, 0–100 scale.
	@param sourceRadius number -- Maximum propagation distance in studs.
	@param distance number -- Actual distance from source to listener in studs.
	@return number -- Intensity after distance falloff, 0–100.
]=]
function SoundPropagator.ComputeDistanceFalloff(sourceIntensity: number, sourceRadius: number, distance: number): number end

-- ─── Stage 2 ─────────────────────────────────────────────────────────────────

--[=[
	Computes the transmission factor through all geometry between two points.

	Returns a multiplier between 0 and 1:
	- `1.0` — completely clear path
	- `0.5` — half the intensity is transmitted
	- `~0` — heavily blocked (never exactly 0 by Beer-Lambert math)

	In `Full` accuracy, the function performs a multi-segment ray march,
	measures each intersected geometry piece using a backward-ray technique,
	and accumulates `thickness × material_coefficient` per segment. In
	`Simple` accuracy, a single raycast is fired and a fixed attenuation is
	applied on hit. In `Skip`, returns `1.0` immediately.

	@param sourcePos Vector3 -- Sound emission origin.
	@param listenerPos Vector3 -- Listener position.
	@param frequency string -- `"low"` | `"mid"` | `"high"` — determines which absorption coefficients are used.
	@param excludeList { Instance } -- Instances excluded from raycasts (e.g. the emitting character).
	@param accuracy string? -- One of `SoundPropagator.Accuracy`. Defaults to `Full`.
	@return number -- Transmission factor, 0–1.
]=]
function SoundPropagator.ComputeOcclusion(sourcePos: Vector3, listenerPos: Vector3, frequency: string, excludeList: { Instance }, accuracy: string?): number end

-- ─── Combined ────────────────────────────────────────────────────────────────

--[=[
	Computes the effective intensity of a [SoundEmission] at a listener
	position, running both propagation stages in sequence.

	This is the primary function external systems call. Returns three values:
	effective intensity, transmission factor, and straight-line distance.

	If the accuracy parameter is omitted, the tier is selected automatically
	based on normalized distance (Full for ≤50%, Simple for 50–100%).

	@param emission SoundEmission -- The emission to evaluate.
	@param listenerPos Vector3 -- The listener's world position.
	@param excludeList { Instance } -- Instances excluded from occlusion raycasts.
	@param accuracy string? -- Optional accuracy tier override.
	@return number -- Effective intensity at listener, 0–100.
	@return number -- Transmission (occlusion) factor, 0–1.
	@return number -- Straight-line distance from source to listener, in studs.
]=]
function SoundPropagator.ComputeEffectiveIntensity(emission: SoundEmission, listenerPos: Vector3, excludeList: { Instance }, accuracy: string?): (number, number, number) end

-- ─── Utility ─────────────────────────────────────────────────────────────────

--[=[
	Returns the recommended accuracy tier for a given emission and listener
	distance.

	| Normalised distance | Tier |
	|---------------------|------|
	| `>= 1.0` (at or beyond radius) | `Skip` |
	| `0.5 – 1.0` | `Simple` |
	| `< 0.5` | `Full` |

	@param emission SoundEmission
	@param distance number -- Distance from source to listener in studs.
	@return string -- One of `SoundPropagator.Accuracy`.
]=]
function SoundPropagator.RecommendAccuracy(emission: SoundEmission, distance: number): string end

return SoundPropagator
