--!native
--!optimize 2
--!strict

--[[
	SoundPropagator
	
	Pure physics layer for acoustic propagation simulation.
	
	Every function in this module is PURE in the strict sense:
		- No state is read or written
		- No signals are fired
		- No external modules are mutated
		- No knowledge of game systems or domain logic
		- Given the same inputs, always produces the same outputs
		  (except for workspace raycasts which depend on geometry)
	
	The Propagator can be called safely from any context — main thread,
	task.spawn, or future Actor parallel context — because it has no
	shared state.
	
	TWO-STAGE PROPAGATION MODEL:
	
		Stage 1 — Distance Falloff
		Sound energy disperses as it travels through free space according
		to the inverse square law: intensity drops as the square of distance.
		This is a fundamental physical law — doubling the distance quarters
		the intensity. The computation is O(1) with no raycasting.
		
		Stage 2 — Geometric Occlusion  
		Sound energy is partially absorbed when it passes through solid
		geometry. The absorption depends on the material's density and
		the thickness of the geometry, and varies by frequency band.
		This is implemented as a ray march that accumulates absorption
		coefficients along the path. Uses exponential decay (Beer-Lambert
		law) rather than linear subtraction for physical accuracy.
	
	FREQUENCY-DEPENDENT ABSORPTION:
	
		The ABSORPTION table encodes per-material, per-frequency-band
		absorption coefficients. The coefficient represents the fraction
		of intensity lost per stud of that material at that frequency.
		
		High-frequency sounds (gunshot crack) are absorbed much more
		aggressively by dense materials than low-frequency sounds
		(explosion rumble). A concrete wall that reduces a gunshot
		to near-silence barely affects the pressure wave of an explosion.
		
		This matches physical reality (Helmholtz resonance, acoustic
		impedance mismatch) and produces emergent gameplay differences:
		a Barrett M98B shot is nearly as detectable through concrete as
		a grenade explosion is, even though the grenade is "louder",
		because the sniper round's high-frequency crack penetrates poorly
		while the explosion's low-frequency energy passes through walls.
	
	PERFORMANCE TIERS:
	
		The occlusion computation has three tiers based on listener distance,
		controlled by the caller through the accuracy parameter.
		
		FULL   — multi-segment ray march, frequency-dependent per material.
		         Used for listeners within 50% of the emission's max radius.
		         Most accurate, most expensive.
		
		SIMPLE — single raycast, material-aware Beer-Lambert with a fixed
		         approximate wall thickness. Used for 50–100% of max radius.
		         More accurate than the old fixed-factor approach with
		         negligible extra cost (one table lookup on hit).
		
		SKIP   — returns 1.0 (no occlusion check at all). Used when the
		         caller has already determined that occlusion doesn't
		         meaningfully affect the result (e.g. distance falloff
		         has already reduced intensity below any threshold).
	
	DIFFRACTION (opt-in per emission):
	
		When an emission is created with Diffraction = true, the propagator
		will attempt to find a diffracted path around blocking geometry
		whenever the direct path is significantly occluded.
		
		Diffraction models sound bending around corners and edges — a
		physically real phenomenon that the base occlusion model ignores.
		A sound in the next corridor is still partially audible even if
		there's no line of sight between source and listener.
		
		Cost: up to DIFFRACTION_RAY_COUNT × 2 extra raycasts per occluded
		query. Enable only for acoustically significant emissions where
		corner-bleed has gameplay meaning (explosions, gunshots for AI
		detection). Footsteps and ambient sounds generally do not need it.
		
		The diffracted transmission is always weaker than a direct clear
		path — DIFFRACTION_TRANSMISSION controls the ceiling. The final
		result is max(direct_transmission, diffracted_transmission), so
		diffraction only helps when the direct path is worse.
]]

local SoundTypes = require(script.Parent.SoundTypes)

type SoundEmission = SoundTypes.SoundEmission

-- ─── Module ──────────────────────────────────────────────────────────────────

local SoundPropagator  = {}
SoundPropagator.__type = "SoundPropagator"

-- ─── Accuracy Levels ─────────────────────────────────────────────────────────

SoundPropagator.Accuracy = table.freeze({
	Full   = "full",    -- full multi-segment ray march
	Simple = "simple",  -- single raycast, material-aware Beer-Lambert
	Skip   = "skip",    -- no occlusion check
})

-- ─── Material Absorption Table ───────────────────────────────────────────────
--[[
	Absorption coefficients per stud of material thickness, per frequency band.
	
	These values are tuned for gameplay feel rather than strict physical
	accuracy. The relative relationships are physically motivated:
		- Dense materials (concrete, brick) absorb more than light ones (wood)
		- High frequencies are absorbed more aggressively than low frequencies
		- Glass is an outlier: it's dense but transmits sound well because
		  it's a poor acoustic resonator at room-audio frequencies
	
	Practical meaning:
		0.10 per stud = 10% intensity loss per stud of that material
		0.45 per stud = 45% intensity loss per stud
		
	Because we use exponential decay (e^-absorption), the actual transmission
	through 1 stud of concrete (mid freq) is e^-0.45 ≈ 0.64, meaning 64% of
	the intensity passes through — which is quite transparent. A 0.8-stud
	concrete wall transmits e^-(0.45*0.8) = e^-0.36 ≈ 0.70, or 70%.
	For the wall to reduce sound to ~10% transmission (barely audible),
	you'd need about 5 studs of concrete or walls stacked several deep.
	This is intentional — completely blocking sound in a game world would
	make the game feel unfair rather than realistic.
]]
local ABSORPTION: { [any]: { low: number, mid: number, high: number } } = {
	[Enum.Material.Concrete] = {
		low  = 0.18,  -- explosion pressure waves pass through concrete relatively well
		mid  = 0.42,  -- voice-range sounds are substantially absorbed
		high = 0.62,  -- gunshot crack is aggressively absorbed by concrete
	},
	[Enum.Material.Brick] = {
		low  = 0.16,
		mid  = 0.38,
		high = 0.55,
	},
	[Enum.Material.Wood] = {
		low  = 0.08,
		mid  = 0.18,
		high = 0.28,
	},
	[Enum.Material.Metal] = {
		low  = 0.12,
		mid  = 0.28,
		high = 0.42,
	},
	[Enum.Material.Glass] = {
		low  = 0.02,  -- glass barely muffles any frequency
		mid  = 0.04,
		high = 0.06,
	},
	[Enum.Material.SmoothPlastic] = {
		low  = 0.06,
		mid  = 0.16,
		high = 0.24,
	},
	[Enum.Material.WoodPlanks] = {
		low  = 0.09,
		mid  = 0.20,
		high = 0.30,
	},
	[Enum.Material.Cobblestone] = {
		low  = 0.14,
		mid  = 0.32,
		high = 0.48,
	},
	[Enum.Material.Slate] = {
		low  = 0.15,
		mid  = 0.35,
		high = 0.50,
	},
	[Enum.Material.DiamondPlate] = {
		low  = 0.10,
		mid  = 0.22,
		high = 0.35,
	},
	[Enum.Material.Fabric] = {
		low  = 0.20,  -- fabric is a good sound absorber (soft furnishings)
		mid  = 0.35,
		high = 0.45,
	},
	[Enum.Material.Grass] = {
		low  = 0.05,
		mid  = 0.10,
		high = 0.15,
	},
	[Enum.Material.Sand] = {
		low  = 0.08,
		mid  = 0.18,
		high = 0.25,
	},
}

-- Fallback for any material not in the table above
local DEFAULT_ABSORPTION = { low = 0.10, mid = 0.22, high = 0.35 }

-- Approximate wall thickness used in the Simple accuracy tier.
-- Simple fires one raycast and gets a hit — but doesn't measure thickness.
-- This constant approximates a typical interior wall (drywall, thin brick)
-- for the Beer-Lambert calculation. Thicker geometry will be under-estimated,
-- but Simple is only used at 50–100% radius where precision matters less.
-- Old approach was a fixed factor (0.35 attenuation regardless of material).
-- New approach: e^-(SIMPLE_APPROX_THICKNESS × material_coefficient), which
-- correctly differentiates glass from concrete at negligible extra cost.
local SIMPLE_APPROX_THICKNESS = 0.5  -- studs

-- Maximum number of geometry segments the full ray march will traverse.
-- This prevents infinite loops from degenerate geometry (very thin overlapping
-- parts) and caps the worst-case raycast budget per query.
local MAX_MARCH_SEGMENTS = 6

-- When accumulated absorption exceeds this threshold, the transmission
-- is already so close to zero that further computation is pointless.
-- e^-4.0 ≈ 0.018, meaning less than 2% intensity passes through.
local ABSORPTION_EARLY_EXIT = 4.0

-- ─── Diffraction Constants ────────────────────────────────────────────────────
--[[
	Diffraction models sound bending around corners and edges.

	When the direct path between source and listener is blocked, the propagator
	samples DIFFRACTION_RAY_COUNT candidate edge points arranged in a circle
	of radius DIFFRACTION_OFFSET studs around the first hit point. For each
	candidate, it checks whether a two-leg path (source→edge, edge→listener)
	is unobstructed. If found, it returns DIFFRACTION_TRANSMISSION as the
	transmission factor for that path.

	DIFFRACTION_TRANSMISSION is deliberately low — diffracted sound is quieter
	than a direct clear path. It represents the energy loss from bending around
	an edge. A value of 0.15 means 15% of post-falloff intensity reaches the
	listener via diffraction — audible but clearly muffled.

	The final transmission is max(direct, diffracted), so diffraction only
	activates when it beats the direct path (i.e. when the direct path is
	heavily occluded).

	Cost per blocked query: up to DIFFRACTION_RAY_COUNT × 2 raycasts.
	With DIFFRACTION_RAY_COUNT = 6, that's up to 12 extra raycasts — only
	incurred when (a) the emission has Diffraction = true, and (b) the direct
	path transmission is below DIFFRACTION_TRANSMISSION (otherwise diffraction
	can't help and is skipped early).
]]
local DIFFRACTION_RAY_COUNT    = 6
local DIFFRACTION_OFFSET       = 1.5   -- studs outward from hit point
local DIFFRACTION_TRANSMISSION = 0.15  -- ceiling transmission for a clean diffracted path

-- ─── Private: Diffraction Sampler ────────────────────────────────────────────

--[[
	Attempts to find a two-leg diffracted path from sourcePos to listenerPos
	by sampling candidate edge points around hitPoint.

	hitPoint is the first geometry surface encountered on the direct path —
	the best candidate for a diffraction edge. Samples are arranged in a circle
	of radius DIFFRACTION_OFFSET perpendicular to the direct direction.

	Returns DIFFRACTION_TRANSMISSION if any clear two-leg path is found,
	or 0 if all candidates are blocked.

	Private — not exported. Only called by ComputeOcclusion.
]]
local function FindDiffractedPath(
	sourcePos   : Vector3,
	listenerPos : Vector3,
	hitPoint    : Vector3,
	rayParams   : RaycastParams
): number
	local direction = (listenerPos - sourcePos).Unit

	-- Build two perpendicular basis vectors for the sampling circle.
	-- If direction is nearly parallel to world UP, use world RIGHT instead
	-- to avoid a degenerate cross product.
	local worldUp = Vector3.new(0, 1, 0)
	local right   = direction:Cross(worldUp)
	if right:Dot(right) < 0.001 then
		right = direction:Cross(Vector3.new(1, 0, 0))
	end
	right = right.Unit
	local upPerp = direction:Cross(right).Unit

	for i = 1, DIFFRACTION_RAY_COUNT do
		local angle     = (i / DIFFRACTION_RAY_COUNT) * math.pi * 2
		local offset    = (right * math.cos(angle) + upPerp * math.sin(angle)) * DIFFRACTION_OFFSET
		local edgePoint = hitPoint + offset

		-- Leg 1: source → edge point
		local toEdge = edgePoint - sourcePos
		if not workspace:Raycast(sourcePos, toEdge, rayParams) then
			-- Leg 2: edge point → listener
			local toListener = listenerPos - edgePoint
			if not workspace:Raycast(edgePoint, toListener, rayParams) then
				-- Clear two-leg path found — no need to check remaining candidates.
				return DIFFRACTION_TRANSMISSION
			end
		end
	end

	return 0
end

-- ─── Stage 1: Distance Falloff ────────────────────────────────────────────────

--[[
	Computes the intensity at a given distance from the source after
	free-space propagation, before any geometric occlusion.
	
	Uses the inverse square law normalized to the emission's maximum radius,
	producing a smooth curve from sourceIntensity at distance 0 to 0 at
	the maximum radius. This normalization ensures the emission has a clean
	"edge" at exactly its configured radius rather than the asymptotic
	approach to zero that pure inverse square would produce.
	
	The formula is: intensity(d) = I₀ × (1 - (d/R)²)
	where I₀ is source intensity, d is distance, R is max radius.
	
	This is a modified inverse-square that gives:
		- Exact source intensity at d=0
		- Zero intensity at d=R
		- A smooth, physically-motivated falloff curve in between
	
	Pure function — no state, no side effects.
	
	@param sourceIntensity  number  Source intensity, 0–100 scale.
	@param sourceRadius     number  Maximum propagation distance in studs.
	@param distance         number  Actual distance from source to listener.
	@return number  Intensity after distance falloff, 0–100.
]]
function SoundPropagator.ComputeDistanceFalloff(
	sourceIntensity : number,
	sourceRadius    : number,
	distance        : number
): number
	-- Beyond maximum radius: completely inaudible
	if distance >= sourceRadius then return 0 end

	-- At the source: full intensity
	if distance <= 0 then return sourceIntensity end

	-- Normalized inverse-square falloff
	local normalizedDist = distance / sourceRadius
	local falloffFactor  = 1 - (normalizedDist * normalizedDist)

	return sourceIntensity * falloffFactor
end

-- ─── Thickness Measurement ────────────────────────────────────────────────────

--[[
	Measures the thickness of a single geometry instance along a given direction.
	
	Shoots a ray from OUTSIDE the geometry backward toward the entry point.
	This two-ray approach correctly handles concave geometry where a single
	forward ray might exit and re-enter the same instance multiple times.
	
	
	@param entryPosition  Vector3       Where the forward ray entered the geometry.
	@param direction      Vector3       Unit direction of the forward ray.
	@param instance       Instance      The geometry instance to measure.
	@param maxThickness   number        Maximum thickness to probe (prevents runaway).
	@return number  Measured thickness in studs, or 0 if measurement fails.
]]
local function MeasureThickness(
	entryPosition : Vector3,
	direction     : Vector3,
	instance      : Instance,
	maxThickness  : number
): number
	local backParams = RaycastParams.new()
	backParams.FilterType = Enum.RaycastFilterType.Include
	backParams.FilterDescendantsInstances = { instance }

	-- Start from maxThickness studs ahead of entry, shoot backward
	local farOrigin   = entryPosition + direction * maxThickness
	local backwardDir = -direction * maxThickness

	local exitResult = workspace:Raycast(farOrigin, backwardDir, backParams)
	if not exitResult then return 0 end

	-- Thickness = distance from entry point to exit point
	return (exitResult.Position - entryPosition).Magnitude
end

-- ─── Stage 2: Geometric Occlusion ─────────────────────────────────────────────

--[[
	Computes the transmission factor through all geometry between two points.
	
	Returns a multiplier between 0 and 1:
		1.0 = completely clear path, full intensity passes through
		0.5 = half the intensity is transmitted
		0.0 = completely blocked
	
	Uses Beer-Lambert exponential decay: transmission = e^(-Σ absorption)
	where the sum accumulates absorption coefficients as the ray passes
	through successive walls. This is physically more accurate than linear
	subtraction because real acoustic absorption follows exponential decay.
	
	The key insight of exponential decay for gameplay:
		- Two half-blocking walls transmit 0.5 × 0.5 = 0.25, not 0
		- You can never achieve complete blockage with finite materials
		- This means any two points in the world always have some acoustic
		  connection, which feels fair rather than arbitrary
	
	SIMPLE TIER CHANGE (vs original):
		Previously returned a fixed `1.0 - 0.35 = 0.65` regardless of material.
		Now performs a material-aware Beer-Lambert calculation using a fixed
		approximate thickness (SIMPLE_APPROX_THICKNESS). Glass still lets
		almost everything through; concrete is significantly more opaque.
		Cost delta: one table lookup on hit — negligible.
	
	DIFFRACTION (opt-in):
		When diffraction is true and the direct path transmission is below
		DIFFRACTION_TRANSMISSION, the propagator will sample candidate edge
		points around the first hit. If any two-leg path is clear, the result
		is max(direct, DIFFRACTION_TRANSMISSION). This means a heavily occluded
		emission can still be partially "heard" around a corner.
	
	@param sourcePos    Vector3        Sound emission origin.
	@param listenerPos  Vector3        Listener position.
	@param frequency    string         "low" | "mid" | "high"
	@param excludeList  { Instance }   Instances to skip in raycasts.
	@param accuracy     string         "full" | "simple" | "skip"
	@param diffraction  boolean?       Whether to attempt diffracted paths when blocked.
	@return number  Transmission factor, 0–1.
]]
function SoundPropagator.ComputeOcclusion(
	sourcePos   : Vector3,
	listenerPos : Vector3,
	frequency   : string,
	excludeList : { Instance },
	accuracy    : string?,
	diffraction : boolean?
): number
	local acc = accuracy or SoundPropagator.Accuracy.Full

	-- Skip tier: no occlusion check at all
	if acc == SoundPropagator.Accuracy.Skip then
		return 1.0
	end

	local direction     = listenerPos - sourcePos
	local totalDistance = direction.Magnitude

	if totalDistance < 0.1 then return 1.0 end -- same position, clear

	local unitDir = direction.Unit

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = excludeList

	-- ── Simple tier ──────────────────────────────────────────────────────────
	-- Single raycast. On hit, compute Beer-Lambert with SIMPLE_APPROX_THICKNESS
	-- and the actual material's absorption coefficient. Previously this was a
	-- fixed factor (0.65 for all materials). Now glass and concrete produce
	-- meaningfully different results at negligible extra cost.
	if acc == SoundPropagator.Accuracy.Simple then
		local result = workspace:Raycast(sourcePos, direction, rayParams)

		if not result then
			return 1.0  -- clear line of sight
		end

		local materialTable      = ABSORPTION[result.Material] or DEFAULT_ABSORPTION
		local coefficient        = (materialTable :: any)[frequency] or materialTable.mid
		local directTransmission = math.exp(-(SIMPLE_APPROX_THICKNESS * coefficient))

		-- Diffraction: only worth trying if diffraction would beat the direct result.
		-- If direct is already above DIFFRACTION_TRANSMISSION ceiling, diffraction
		-- cannot improve it — skip the extra raycasts.
		if diffraction and directTransmission < DIFFRACTION_TRANSMISSION then
			local diffractedTransmission = FindDiffractedPath(
				sourcePos, listenerPos, result.Position, rayParams
			)
			return math.max(directTransmission, diffractedTransmission)
		end

		return directTransmission
	end

	-- ── Full tier ─────────────────────────────────────────────────────────────
	-- Multi-segment ray march with per-material, per-frequency absorption.
	local currentOrigin      = sourcePos
	local distanceTraveled   = 0
	local totalAbsorption    = 0
	local segmentCount       = 0
	local maxThicknessProbe  = math.min(totalDistance, 20)
	local firstHitPoint      : Vector3? = nil  -- stored for diffraction if needed

	while distanceTraveled < totalDistance and segmentCount < MAX_MARCH_SEGMENTS do
		segmentCount += 1

		local remaining = totalDistance - distanceTraveled
		local result    = workspace:Raycast(currentOrigin, unitDir * remaining, rayParams)

		-- No more geometry between current position and listener
		if not result then break end

		-- Store the first hit point — used by diffraction if the path is too blocked.
		if not firstHitPoint then
			firstHitPoint = result.Position
		end

		-- Measure the thickness of this geometry using the backward-ray technique
		local thickness = MeasureThickness(
			result.Position,
			unitDir,
			result.Instance,
			maxThicknessProbe
		)

		-- Clamp thickness to what remains of the total path
		thickness = math.min(thickness, totalDistance - distanceTraveled)

		-- Look up absorption for this material at this frequency
		local materialTable = ABSORPTION[result.Material] or DEFAULT_ABSORPTION
		local coefficient   = (materialTable :: any)[frequency] or materialTable.mid

		-- Accumulate absorption
		totalAbsorption = totalAbsorption + (thickness * coefficient)

		-- Early exit: absorption is already so high that transmission ≈ 0.
		-- Still attempt diffraction if enabled — a path that's practically
		-- blocked is exactly the case where diffraction might help.
		if totalAbsorption >= ABSORPTION_EARLY_EXIT then
			if diffraction and firstHitPoint then
				return FindDiffractedPath(sourcePos, listenerPos, firstHitPoint, rayParams)
			end
			return 0
		end

		-- Advance origin past this geometry.
		-- The +0.05 nudge prevents re-hitting the same surface due to
		-- floating point imprecision at the exit point.
		local advance    = (result.Position - currentOrigin).Magnitude + thickness + 0.05
		distanceTraveled = distanceTraveled + advance
		currentOrigin    = sourcePos + unitDir * distanceTraveled
	end

	-- Beer-Lambert law: transmission = e^(-totalAbsorption)
	local directTransmission = math.exp(-totalAbsorption)

	-- Diffraction: same early-exit logic as Simple tier.
	-- Only sample if diffraction can actually improve on the direct result.
	if diffraction and firstHitPoint and directTransmission < DIFFRACTION_TRANSMISSION then
		local diffractedTransmission = FindDiffractedPath(
			sourcePos, listenerPos, firstHitPoint, rayParams
		)
		return math.max(directTransmission, diffractedTransmission)
	end

	return directTransmission
end

-- ─── Combined: Effective Intensity ────────────────────────────────────────────

--[[
	Computes the effective intensity of a sound emission at a listener position.
	
	This is the PRIMARY function that external systems call. It runs both
	propagation stages in sequence and returns the final intensity number.
	
	The accuracy parameter controls the occlusion tier selection.
	Callers that already know the distance can use it to select the
	appropriate tier. If not provided, Full accuracy is used.
	
	@param emission      SoundEmission  The emission to evaluate.
	@param listenerPos   Vector3        The listener's world position.
	@param excludeList   { Instance }   Instances to skip in occlusion raycasts.
	@param accuracy      string?        "full" | "simple" | "skip"
	@return number  intensity      Effective intensity at listener, 0–100.
	@return number  occlusion      Transmission factor, 0–1 (1 = clear).
	@return number  distance       Straight-line distance, in studs.
]]
function SoundPropagator.ComputeEffectiveIntensity(
	emission    : SoundEmission,
	listenerPos : Vector3,
	excludeList : { Instance },
	accuracy    : string?
): (number, number, number)
	local distance = (emission.Position - listenerPos).Magnitude

	-- Stage 1: distance falloff (O(1), no raycasting)
	local postFalloff = SoundPropagator.ComputeDistanceFalloff(
		emission.Intensity,
		emission.Radius,
		distance
	)

	-- Skip occlusion if distance falloff already eliminated the sound.
	-- There is no meaningful difference between 0.001 and 0 intensity —
	-- both are inaudible. Skipping the raycasts here saves significant
	-- CPU when many emissions are distant and already faded.
	if postFalloff <= 0.5 then
		return 0, 0, distance
	end

	-- Resolve accuracy tier based on distance if not specified
	local acc = accuracy
	if not acc then
		local normalizedDist = distance / emission.Radius
		if normalizedDist <= 0.5 then
			acc = SoundPropagator.Accuracy.Full
		else
			acc = SoundPropagator.Accuracy.Simple
		end
	end

	-- Stage 2: geometric occlusion
	local excludes = excludeList
	if emission.Source then
		-- Ensure the emission source is excluded from occlusion raycasts.
		-- We don't want the geometry of the sound source itself to block
		-- the sound it just produced.
		local withSource = table.clone(excludeList)
		table.insert(withSource, emission.Source)
		excludes = withSource
	end

	local occlusion = SoundPropagator.ComputeOcclusion(
		emission.Position,
		listenerPos,
		emission.Frequency,
		excludes,
		acc,
		emission.Diffraction
	)

	local effectiveIntensity = postFalloff * occlusion
	return effectiveIntensity, occlusion, distance
end

-- ─── Utility: Recommended Accuracy ───────────────────────────────────────────

--[[
	Returns the recommended accuracy tier for a given emission and listener
	distance. External systems can call this to pre-compute the tier before
	calling ComputeEffectiveIntensity, or use it to batch-decide tiers for
	multiple agents at once.
	
	@param emission  SoundEmission
	@param distance  number  Distance from source to listener.
	@return string  One of SoundPropagator.Accuracy values.
]]
function SoundPropagator.RecommendAccuracy(
	emission : SoundEmission,
	distance : number
): string
	if distance >= emission.Radius then
		return SoundPropagator.Accuracy.Skip
	end

	local normalized = distance / emission.Radius
	if normalized <= 0.5 then
		return SoundPropagator.Accuracy.Full
	else
		return SoundPropagator.Accuracy.Simple
	end
end

return table.freeze(SoundPropagator)