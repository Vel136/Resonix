--!native
--!optimize 2
--!strict

--[[
	ResonixNet/Authority/FireValidator.lua

	Server-side validation of incoming client emission requests.

	Stateless per-request. All shared mutable state (session counts, rate
	limiter tokens) lives in Session and RateLimiter and is passed on each
	call, making this module trivially testable with mock objects.

	Checks run cheapest-to-most-expensive, with the destructive check last:
	  1. Player exists and is in game         — O(1) table read
	  2. Session active / concurrent cap      — O(1) counter check
	  3. Origin distance from character        — O(1) vector dot product
	  4. Preset hash is registered             — O(1) hash table lookup
	  5. Rate limiter token available          — O(1) arithmetic, DESTRUCTIVE

	Checks 3-4 are non-destructive and gate check 5. An exploiter sending
	bad origins or unknown preset hashes is rejected before any token is
	consumed, preventing token-drain attacks.

	Rejection reasons are logged server-side only. The client receives no
	acknowledgement — silence is the only response to a rejected request.
	Sending rejection reasons would let exploiters probe which checks are
	active and calibrate their spoofs.

	SERVER-ONLY. Errors at require() time if loaded on the client.
]]

local Identity      = "FireValidator"

local FireValidator = {}
FireValidator.__type = Identity

-- ─── References ──────────────────────────────────────────────────────────────

local Core = script.Parent.Parent.Core

-- ─── Module References ───────────────────────────────────────────────────────

local Authority  = require(Core.Authority)
local LogService = require(Core.Logger)
local Session    = require(Core.Session)

Authority.AssertServer("FireValidator")

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, true)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local math_sqrt     = math.sqrt
local string_format = string.format

-- ─── Validation reason strings ────────────────────────────────────────────────

local Reason = table.freeze({
	Passed          = "Passed",
	PlayerNotFound  = "PlayerNotFound",
	SessionInactive = "SessionInactive",
	ConcurrentLimit = "ConcurrentLimit",
	OriginTolerance = "OriginTolerance",
	UnknownPreset   = "UnknownPreset",
	RateLimited     = "RateLimited",
})

-- ─── Helpers ─────────────────────────────────────────────────────────────────

local function GetCharacterRoot(Player: Player): BasePart?
	local Char = Player.Character
	if not Char then return nil end
	return Char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

-- ─── API ─────────────────────────────────────────────────────────────────────

-- Validate an incoming emission payload from a client.
-- Returns { Passed: boolean, Reason: string }.
-- PresetRegistry, Session, and RateLimiter are passed as arguments so this
-- module has no concrete instance dependencies.
function FireValidator.Validate(
	Player_          : Player,
	Payload          : { PresetHash: number, Position: Vector3 },
	Session_         : any,
	RateLimiter_     : any,
	PresetRegistry_  : any,
	ResolvedConfig   : any
): { Passed: boolean, Reason: string }

	-- ── Check 1: Player in game ──────────────────────────────────────────────
	if not Player_ or not Player_.Parent then
		return { Passed = false, Reason = Reason.PlayerNotFound }
	end

	-- ── Check 2: Session / concurrent cap ───────────────────────────────────
	local SessionResult = Session_:CanEmit(Player_)
	if SessionResult ~= Session.Status.Ready then
		if SessionResult == Session.Status.AtLimit then
			Logger:Warn(string_format(
				"FireValidator: player '%s' (UserId: %d) rejected — concurrent emission cap reached (%d active)",
				Player_.Name, Player_.UserId, ResolvedConfig.MaxConcurrentEmits
			))
			return { Passed = false, Reason = Reason.ConcurrentLimit }
		else
			Logger:Warn(string_format(
				"FireValidator: player '%s' (UserId: %d) rejected — session inactive",
				Player_.Name, Player_.UserId
			))
			return { Passed = false, Reason = Reason.SessionInactive }
		end
	end

	-- ── Check 3: Origin tolerance ────────────────────────────────────────────
	-- Only checked when the character is loaded. During respawn the root may
	-- be nil — in that case we accept the position. The tolerance check catches
	-- obvious teleport exploits once the character has a valid position.
	local Root = GetCharacterRoot(Player_)
	if Root then
		local OriginTolerance = ResolvedConfig.MaxOriginTolerance
		local Delta           = Payload.Position - Root.Position
		local DistanceSq      = Delta:Dot(Delta)
		if DistanceSq > OriginTolerance * OriginTolerance then
			Logger:Warn(string_format(
				"FireValidator: player '%s' (UserId: %d) rejected — origin %.1f studs from character (tolerance: %.1f)",
				Player_.Name, Player_.UserId, math_sqrt(DistanceSq), OriginTolerance
			))
			return { Passed = false, Reason = Reason.OriginTolerance }
		end
	end

	-- ── Check 4: Preset hash is registered ──────────────────────────────────
	local PresetKey = PresetRegistry_:KeyOf(Payload.PresetHash)
	if not PresetKey then
		Logger:Warn(string_format(
			"FireValidator: player '%s' (UserId: %d) rejected — unknown preset hash %d",
			Player_.Name, Player_.UserId, Payload.PresetHash
		))
		return { Passed = false, Reason = Reason.UnknownPreset }
	end

	-- ── Check 5: Rate limiter token (DESTRUCTIVE) ────────────────────────────
	if not RateLimiter_:TryConsume(Player_) then
		Logger:Warn(string_format(
			"FireValidator: player '%s' (UserId: %d) rejected — rate limited",
			Player_.Name, Player_.UserId
		))
		return { Passed = false, Reason = Reason.RateLimited }
	end

	return { Passed = true, Reason = Reason.Passed }
end

FireValidator.Reason = Reason

-- ─── Module Return ────────────────────────────────────────────────────────────

return table.freeze(setmetatable(FireValidator, {
	__index = function(_, Key)
		Logger:Warn(string_format("FireValidator: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, _Value)
		Logger:Error(string_format("FireValidator: write to protected key '%s'", tostring(Key)))
	end,
}))
