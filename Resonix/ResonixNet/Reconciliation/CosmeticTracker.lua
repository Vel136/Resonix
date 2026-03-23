--!native
--!optimize 2
--!strict

--[[
	ResonixNet/Reconciliation/CosmeticTracker.lua

	Tracks client-side emission IDs by server emission ID.

	When the client receives a replicated CHANNEL_EMIT, it calls
	Resonix:EmitPreset() locally and stores the returned emission ID here,
	keyed by the server's authoritative emission ID.

	This mapping is needed for two reasons:

	  1. Cancel propagation — when CHANNEL_CANCEL arrives carrying a
	     server emission ID, we look up the local emission ID to call
	     Resonix:Cancel(). Without this, the local buffer would never
	     hear about cancellations and would play the sound to completion
	     even if (for example) the player was killed mid-vending-machine.

	  2. State sync correctness — the late-join CHANNEL_STATE batch carries
	     server emission IDs. If the emission was already present in the
	     local buffer (from an earlier replicated CHANNEL_EMIT before the
	     player joined), we skip re-emitting to avoid doubling. The tracker
	     tells us whether a given server emission ID is already live locally.

	Unlike VetraNet's CosmeticTracker which maps to full Cast objects,
	Resonix's version maps to plain string emission IDs (Resonix:Emit()
	returns a GUID string). The structure is otherwise identical.

	CLIENT-ONLY. Errors at require() time if loaded on the server.
]]

local Identity        = "CosmeticTracker"

local CosmeticTracker = {}
CosmeticTracker.__type = Identity

local CosmeticTrackerMetatable = table.freeze({ __index = CosmeticTracker })

-- ─── References ──────────────────────────────────────────────────────────────

local Core = script.Parent.Parent.Core

-- ─── Module References ───────────────────────────────────────────────────────

local Authority  = require(Core.Authority)
local LogService = require(Core.Logger)

Authority.AssertClient("CosmeticTracker")

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, false)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local table_clear   = table.clear
local string_format = string.format

-- ─── Factory ─────────────────────────────────────────────────────────────────

function CosmeticTracker.new(): any
	return setmetatable({
		-- [serverEmissionId: number] → localEmissionId (string GUID from Resonix:Emit)
		_ServerToLocal = {},
	}, CosmeticTrackerMetatable)
end

-- ─── API ─────────────────────────────────────────────────────────────────────

-- Associate a server emission ID with the local emission ID produced by
-- Resonix:EmitPreset() or Resonix:Emit(). Called immediately after the local
-- emit so CHANNEL_CANCEL messages can find the right emission to cancel.
function CosmeticTracker.Register(self: any, ServerEmissionId: number, LocalEmissionId: string)
	if self._ServerToLocal[ServerEmissionId] then
		Logger:Warn(string_format(
			"CosmeticTracker.Register: serverEmissionId %d already registered — overwriting",
			ServerEmissionId
		))
	end
	self._ServerToLocal[ServerEmissionId] = LocalEmissionId
end

-- Remove the mapping when the emission expires (via background prune) or
-- is cancelled. Called from the CHANNEL_CANCEL handler in ClientHooks.
function CosmeticTracker.Unregister(self: any, ServerEmissionId: number)
	self._ServerToLocal[ServerEmissionId] = nil
end

-- Look up the local emission ID for a given server emission ID.
-- Returns nil if not found — either never received or already expired.
function CosmeticTracker.GetLocal(self: any, ServerEmissionId: number): string?
	return self._ServerToLocal[ServerEmissionId]
end

-- Returns true if the server emission ID is currently tracked.
-- Used by the late-join CHANNEL_STATE decoder to skip emissions already live.
function CosmeticTracker.IsTracked(self: any, ServerEmissionId: number): boolean
	return self._ServerToLocal[ServerEmissionId] ~= nil
end

-- Returns all current serverEmissionId → localEmissionId mappings.
-- Used for bulk cleanup (e.g. on Destroy).
function CosmeticTracker.GetAll(self: any): { [number]: string }
	return self._ServerToLocal
end

-- Idempotent destroy.
function CosmeticTracker.Destroy(self: any)
	if self._Destroyed then return end
	self._Destroyed = true
	table_clear(self._ServerToLocal)
	self._ServerToLocal = nil
	setmetatable(self, nil)
end

-- ─── Module Return ────────────────────────────────────────────────────────────

return table.freeze(setmetatable(CosmeticTracker, {
	__index = function(_, Key)
		Logger:Warn(string_format("CosmeticTracker: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, _Value)
		Logger:Error(string_format("CosmeticTracker: write to protected key '%s'", tostring(Key)))
	end,
}))
