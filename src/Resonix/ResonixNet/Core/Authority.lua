--!native
--!optimize 2
--!strict

--[[
	ResonixNet/Core/Authority.lua

	Determines whether the current runtime is server or client.

	Both flags are computed once at module load and stored as booleans.
	All callers get an O(1) table-read instead of a repeated RunService call.
	AssertServer / AssertClient surface misconfigurations at require() time
	rather than producing confusing nil errors deep in a frame loop.
]]

local Identity  = "Authority"

local Authority = {}
Authority.__type = Identity

-- ─── References ──────────────────────────────────────────────────────────────

local RunService = game:GetService("RunService")

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local string_format = string.format

-- ─── Constants ───────────────────────────────────────────────────────────────

local IS_SERVER: boolean = RunService:IsServer()

-- ─── API ─────────────────────────────────────────────────────────────────────

function Authority.IsServer(): boolean
	return IS_SERVER
end

function Authority.IsClient(): boolean
	return not IS_SERVER
end

-- Errors immediately when a server-only module is required from the client,
-- or a client-only module is required from the server.
function Authority.AssertServer(Context: string)
	if not IS_SERVER then
		error(string_format(
			"[ResonixNet.%s] This module is server-only and must not be required on the client.",
			Context
		), 2)
	end
end

function Authority.AssertClient(Context: string)
	if IS_SERVER then
		error(string_format(
			"[ResonixNet.%s] This module is client-only and must not be required on the server.",
			Context
		), 2)
	end
end

-- ─── Module Return ────────────────────────────────────────────────────────────

return table.freeze(setmetatable(Authority, {
	__index = function(_, Key)
		error(string_format("[ResonixNet.Authority] Nil key '%s'", tostring(Key)), 2)
	end,
	__newindex = function(_, Key, _Value)
		error(string_format("[ResonixNet.Authority] Write to protected key '%s'", tostring(Key)), 2)
	end,
}))
