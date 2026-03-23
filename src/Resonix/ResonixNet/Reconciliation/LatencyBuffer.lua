--!native
--!optimize 2
--!strict

--[[
	ResonixNet/Reconciliation/LatencyBuffer.lua

	Provides the estimated half-RTT delay applied before reconstructing
	server emissions on the client (via task.delay in ClientHooks).

	What the delay does:
	  When a CHANNEL_EMIT packet arrives, ClientHooks waits GetEffectiveDelay()
	  seconds before calling Resonix:EmitPreset(). The reconstructed emission
	  gets a fresh EmittedAt = os.clock() at construction time and a full
	  Duration + DECAY_WINDOW lifetime from that point — no timestamp
	  back-dating occurs here.

	  The delay staggers cosmetic reactions (footstep indicators, threat HUD)
	  so they fire slightly after packet arrival rather than all at once on
	  the same tick, preventing a burst of UI updates on a single frame when
	  a state batch is delivered.

	  For timestamp-accurate remaining-lifetime reconstruction (late-join),
	  use CHANNEL_STATE + DriftCorrector instead — that path converts
	  server-clock ExpiresAt to local os.clock() space and computes a
	  synthetic duration so the emission expires at the correct wall-clock
	  moment regardless of when the client joined.

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
