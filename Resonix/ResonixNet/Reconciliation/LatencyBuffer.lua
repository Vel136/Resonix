--!native
--!optimize 2
--!strict

--[[
	ResonixNet/Reconciliation/LatencyBuffer.lua

	Delays client-side emission reconstruction by an estimated half-RTT.

	Why does this matter for sounds?
	When the server emits a gunshot at t=0 and the AI query runs on the server
	at t=0.1, the server correctly detects the sound. The replicated emission
	arrives on the client at t=0 + RTT. Without a delay, the client's emission
	was "heard" at t=RTT, meaning the client's own AI reactions (footstep
	visualisers, threat indicators, cosmetic hit markers) are RTT seconds
	behind the server's simulation. For sounds with short decay windows
	(gunshots at 0.05s + 0.6s = 0.65s total lifetime), a 200ms RTT consumes
	30% of the audible window before the client even starts.

	By delaying reconstruction by half-RTT, the client's emission is
	effectively "pre-aged" correctly — its local EmittedAt aligns with
	what the server clock would have been at the moment of actual emission.

	CLIENT-ONLY. Errors at require() time if loaded on the server.
]]

local Identity      = "LatencyBuffer"

local LatencyBuffer = {}
LatencyBuffer.__type = Identity

-- ─── References ──────────────────────────────────────────────────────────────

local Core    = script.Parent.Parent.Core
local Players = game:GetService("Players")

-- ─── Module References ───────────────────────────────────────────────────────

local Authority  = require(Core.Authority)
local LogService = require(Core.Logger)

Authority.AssertClient("LatencyBuffer")

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, false)

-- ─── Module References ───────────────────────────────────────────────────────

local LocalPlayer = Players.LocalPlayer

-- ─── API ─────────────────────────────────────────────────────────────────────

-- Returns the current estimated round-trip time in seconds.
function LatencyBuffer.GetRTT(): number
	return LocalPlayer:GetNetworkPing()
end

-- Returns the estimated one-way delay (server→client) in seconds.
-- Halving RTT assumes symmetric paths — asymmetric connections introduce
-- < 20ms error in typical cases, imperceptible for sound timing.
function LatencyBuffer.GetDelay(): number
	return LatencyBuffer.GetRTT() / 2
end

-- Returns true when a delay should be applied.
-- When ConfigOverride is provided and non-zero, always honour it.
-- Skip when delay would be < 1ms to avoid unnecessary task.delay overhead.
function LatencyBuffer.ShouldBuffer(ConfigOverride: number): boolean
	if ConfigOverride ~= 0 then
		return ConfigOverride > 0.001
	end
	return LatencyBuffer.GetDelay() > 0.001
end

-- Returns the effective delay to use: ConfigOverride if set, else half-RTT.
function LatencyBuffer.GetEffectiveDelay(ConfigOverride: number): number
	if ConfigOverride ~= 0 then
		return ConfigOverride
	end
	return LatencyBuffer.GetDelay()
end

-- ─── Module Return ────────────────────────────────────────────────────────────

return table.freeze(setmetatable(LatencyBuffer, {
	__index = function(_, Key)
		Logger:Warn(string_format("LatencyBuffer: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, _Value)
		Logger:Error(string_format("LatencyBuffer: write to protected key '%s'", tostring(Key)))
	end,
}))
