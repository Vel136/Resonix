--!native
--!optimize 2
--!strict

--[[
	ResonixNet/Core/Session.lua

	Tracks active network sessions per player on the server.

	A session is created the first time a player is registered and destroyed
	when they leave. It tracks how many emissions the player currently has
	active, allowing FireValidator to enforce the MaxConcurrentEmits cap.

	SERVER-ONLY. Errors at require() time if loaded on the client.
]]

local Identity = "Session"

local Session  = {}
Session.__type = Identity

local SessionMetatable = table.freeze({ __index = Session })

-- ─── References ──────────────────────────────────────────────────────────────

local Core = script.Parent

-- ─── Module References ───────────────────────────────────────────────────────

local Authority  = require(Core.Authority)
local LogService = require(Core.Logger)

Authority.AssertServer("Session")

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, true)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local math_max      = math.max
local table_clear   = table.clear
local string_format = string.format

-- ─── Session status values ────────────────────────────────────────────────────

local SessionStatus = table.freeze({
	Ready    = "ready",
	AtLimit  = "cap",
	Inactive = "inactive",
})

-- ─── Factory ─────────────────────────────────────────────────────────────────

function Session.new(ResolvedConfig: any): any
	local self = setmetatable({
		_Config    = ResolvedConfig,
		_Destroyed = false,
		_Sessions  = {},
	}, SessionMetatable)
	return self
end

-- ─── API ─────────────────────────────────────────────────────────────────────

-- Create a fresh session for a player. Called on PlayerAdded.
-- Duplicate Register is a no-op with a warning — PlayerAdded can fire twice.
function Session.Register(self: any, Player: Player)
	if self._Sessions[Player] then
		Logger:Warn(string_format(
			"Session.Register: player '%s' already has an active session — ignoring duplicate",
			Player.Name
		))
		return
	end
	self._Sessions[Player] = {
		_ActiveEmissionIds = {} :: { [number]: true },
		_EmissionCount     = 0,
	}
end

-- Destroy the session on PlayerRemoving.
function Session.Unregister(self: any, Player: Player)
	-- Not an error — PlayerRemoving fires for players who never emitted.
	self._Sessions[Player] = nil
end

-- Returns a SessionStatus string.
-- Does NOT lazily create sessions — an Inactive result surfaces a real gap.
function Session.CanEmit(self: any, Player: Player): string
	local Entry = self._Sessions[Player]
	if not Entry then
		return SessionStatus.Inactive
	end
	if Entry._EmissionCount >= self._Config.MaxConcurrentEmits then
		return SessionStatus.AtLimit
	end
	return SessionStatus.Ready
end

-- Record a new active emission for the player. Called after FireValidator passes.
function Session.AddEmission(self: any, Player: Player, EmissionId: number)
	local Entry = self._Sessions[Player]
	if not Entry then
		Logger:Warn(string_format(
			"Session.AddEmission: no session for player '%s' — creating lazily",
			Player.Name
		))
		self:Register(Player)
		Entry = self._Sessions[Player]
	end
	if Entry._ActiveEmissionIds[EmissionId] then
		Logger:Warn(string_format(
			"Session.AddEmission: duplicate emissionId %d for player '%s' — ignoring",
			EmissionId, Player.Name
		))
		return
	end
	Entry._ActiveEmissionIds[EmissionId] = true
	Entry._EmissionCount += 1
end

-- Release an emission from the player's active budget when it expires or is cancelled.
function Session.RemoveEmission(self: any, Player: Player, EmissionId: number)
	local Entry = self._Sessions[Player]
	if not Entry then return end
	if not Entry._ActiveEmissionIds[EmissionId] then return end
	Entry._ActiveEmissionIds[EmissionId] = nil
	Entry._EmissionCount = math_max(0, Entry._EmissionCount - 1)
end

-- Returns all currently active emission IDs for a player.
function Session.GetActiveEmissions(self: any, Player: Player): { number }
	local Entry = self._Sessions[Player]
	if not Entry then return {} end
	local Result = {}
	for Id in Entry._ActiveEmissionIds do
		Result[#Result + 1] = Id
	end
	return Result
end

-- Idempotent.
function Session.Destroy(self: any)
	if self._Destroyed then return end
	self._Destroyed = true
	table_clear(self._Sessions)
	self._Sessions = nil
	setmetatable(self, nil)
end

Session.Status = SessionStatus

-- ─── Module Return ────────────────────────────────────────────────────────────

return table.freeze(setmetatable(Session, {
	__index = function(_, Key)
		Logger:Warn(string_format("Session: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, _Value)
		Logger:Error(string_format("Session: write to protected key '%s'", tostring(Key)))
	end,
}))
