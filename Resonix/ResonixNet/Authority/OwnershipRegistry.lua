--!native
--!optimize 2
--!strict

--[[
	ResonixNet/Authority/OwnershipRegistry.lua

	Maps server emission ID to owning player on the server.

	Why does this exist?
	Without it, the server has no way to know which player produced a given
	emission. When a player disconnects mid-emission (e.g. leaves while a
	vending machine interaction is active), the server needs to cancel their
	emissions. Without ownership tracking, orphaned emissions would continue
	attracting AI for their full duration after the player has left.

	Also used to prevent a malicious client from cancelling another player's
	emission by sending a fake cancel request — only the emission's owner or
	the server itself can cancel it.

	Emission IDs are u32 values assigned by the server. The server assigns a
	fresh ID to every validated emission. When the emission expires or is
	cancelled the mapping is removed.

	SERVER-ONLY. Errors at require() time if loaded on the client.
]]

local Identity          = "OwnershipRegistry"

local OwnershipRegistry = {}
OwnershipRegistry.__type = Identity

local OwnershipRegistryMetatable = table.freeze({ __index = OwnershipRegistry })

-- ─── References ──────────────────────────────────────────────────────────────

local Core = script.Parent.Parent.Core

-- ─── Module References ───────────────────────────────────────────────────────

local Authority  = require(Core.Authority)
local LogService = require(Core.Logger)

Authority.AssertServer("OwnershipRegistry")

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, false)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local table_clear   = table.clear
local string_format = string.format

-- ─── Factory ─────────────────────────────────────────────────────────────────

function OwnershipRegistry.new(): any
	return setmetatable({
		-- [emissionId: number] → Player
		_EmissionToPlayer = {},
		-- [Player] → { emissionId: number } (set of emission IDs owned by player)
		-- Weak-keyed so a disconnected player doesn't prevent GC of their entry.
		_PlayerToEmissions = setmetatable({}, { __mode = "k" }),
	}, OwnershipRegistryMetatable)
end

-- ─── API ─────────────────────────────────────────────────────────────────────

-- Register ownership of an emission ID for a player.
-- Called immediately after the server validates and emits.
function OwnershipRegistry.Register(self: any, EmissionId: number, Player: Player)
	if self._EmissionToPlayer[EmissionId] then
		Logger:Warn(string_format(
			"OwnershipRegistry.Register: emissionId %d already registered — overwriting",
			EmissionId
		))
	end
	self._EmissionToPlayer[EmissionId] = Player

	local PlayerEmissions = self._PlayerToEmissions[Player]
	if not PlayerEmissions then
		PlayerEmissions = {}
		self._PlayerToEmissions[Player] = PlayerEmissions
	end
	PlayerEmissions[EmissionId] = true
end

-- Release an emission mapping when it expires or is cancelled.
function OwnershipRegistry.Unregister(self: any, EmissionId: number)
	local Owner = self._EmissionToPlayer[EmissionId]
	if Owner then
		local PlayerEmissions = self._PlayerToEmissions[Owner]
		if PlayerEmissions then
			PlayerEmissions[EmissionId] = nil
		end
	end
	self._EmissionToPlayer[EmissionId] = nil
end

-- Returns the player who owns the given emission ID, or nil if not found.
-- nil means it was either a server-authority emission or has already expired.
function OwnershipRegistry.GetOwner(self: any, EmissionId: number): Player?
	return self._EmissionToPlayer[EmissionId]
end

-- Returns true if the given player owns the given emission ID.
-- Used to validate client cancel requests.
function OwnershipRegistry.IsOwner(self: any, EmissionId: number, Player: Player): boolean
	return self._EmissionToPlayer[EmissionId] == Player
end

-- Returns all emission IDs currently owned by the given player.
-- Used during disconnect cleanup to cancel all of their active emissions.
function OwnershipRegistry.GetEmissionsForPlayer(self: any, Player: Player): { number }
	local PlayerEmissions = self._PlayerToEmissions[Player]
	if not PlayerEmissions then return {} end
	local Result = {}
	for Id in PlayerEmissions do
		Result[#Result + 1] = Id
	end
	return Result
end

-- Idempotent destroy.
function OwnershipRegistry.Destroy(self: any)
	if self._Destroyed then return end
	self._Destroyed = true
	table_clear(self._EmissionToPlayer)
	table_clear(self._PlayerToEmissions)
	self._EmissionToPlayer  = nil
	self._PlayerToEmissions = nil
	setmetatable(self, nil)
end

-- ─── Module Return ────────────────────────────────────────────────────────────

return table.freeze(setmetatable(OwnershipRegistry, {
	__index = function(_, Key)
		Logger:Warn(string_format("OwnershipRegistry: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, _Value)
		Logger:Error(string_format("OwnershipRegistry: write to protected key '%s'", tostring(Key)))
	end,
}))
