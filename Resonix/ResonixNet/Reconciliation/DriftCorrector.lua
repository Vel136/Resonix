--!native
--!optimize 2
--!strict

--[[
	ResonixNet/Reconciliation/DriftCorrector.lua

	Corrects client-side emission ExpiresAt timestamps using server-clock
	offset computed from each incoming network message.

	The problem:
	Resonix uses os.clock() internally for EmittedAt and ExpiresAt. The
	server's os.clock() and the client's os.clock() are independent and
	diverge over time. A VendingMachine emission that the server records
	as "expires at os.clock()=1000.0" will be interpreted differently on
	a client whose os.clock() is 1000.3 at the same moment — the emission
	would appear to have already expired 0.3 seconds ago.

	The solution:
	Every emission received from the server carries a ServerTimestamp in
	workspace:GetServerTimeNow() space, which IS synchronized between server
	and client. The client can compute:

	    clockOffset = workspace:GetServerTimeNow() - os.clock()

	This offset converts server-clock values to local os.clock() values.
	Given the server's serverEmittedAt (in GetServerTimeNow() space), the
	client reconstructs:

	    localEmittedAt = serverEmittedAt - clockOffset
	    localExpiresAt = serverExpiresAt - clockOffset

	The offset is smoothed exponentially to absorb measurement jitter
	(GetServerTimeNow() can have micro-second noise). The smoothing rate
	is controlled by ClockSyncRate from Config.

	CLIENT-ONLY. Errors at require() time if loaded on the server.
]]

local Identity       = "DriftCorrector"

local DriftCorrector = {}
DriftCorrector.__type = Identity

local DriftCorrectorMetatable = table.freeze({ __index = DriftCorrector })

-- ─── References ──────────────────────────────────────────────────────────────

local Core = script.Parent.Parent.Core

-- ─── Module References ───────────────────────────────────────────────────────

local Authority  = require(Core.Authority)
local LogService = require(Core.Logger)

Authority.AssertClient("DriftCorrector")

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, false)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local math_min      = math.min
local math_abs      = math.abs
local string_format = string.format

-- ─── Factory ─────────────────────────────────────────────────────────────────

function DriftCorrector.new(ResolvedConfig: any): any
	return setmetatable({
		-- Smoothed clock offset: workspace:GetServerTimeNow() - os.clock()
		-- Initialised from the first sample on the first message received.
		_ClockOffset    = nil :: number?,
		_ClockSyncRate  = ResolvedConfig.ClockSyncRate,
		_Destroyed      = false,
	}, DriftCorrectorMetatable)
end

-- ─── API ─────────────────────────────────────────────────────────────────────

-- Update the smoothed clock offset from a message that carries a ServerTimestamp.
-- ServerTimestamp is workspace:GetServerTimeNow() at the moment the server sent
-- the message. This is called every time a CHANNEL_EMIT or CHANNEL_STATE arrives.
--
-- The exponential blend: offset = lerp(currentOffset, rawOffset, alpha)
-- converges to the true offset within a few packets while filtering out
-- per-packet noise from network jitter.
function DriftCorrector.UpdateOffset(self: any, ServerTimestamp: number, DeltaTime: number)
	local RawOffset = ServerTimestamp - os.clock()

	if self._ClockOffset == nil then
		-- First sample: seed directly without blending.
		self._ClockOffset = RawOffset
		Logger:Debug(string_format(
			"DriftCorrector: initial clock offset = %.4fs",
			RawOffset
		))
		return
	end

	-- Exponential blend. Alpha = clamp(deltaTime * rate, 0, 1).
	local Alpha  = math_min(DeltaTime * self._ClockSyncRate, 1)
	local OldOff = self._ClockOffset
	self._ClockOffset = OldOff + (RawOffset - OldOff) * Alpha

	if math_abs(RawOffset - OldOff) > 0.05 then
		Logger:Debug(string_format(
			"DriftCorrector: clock offset jumped %.3fs → applying correction",
			RawOffset - OldOff
		))
	end
end

-- Converts a server-clock timestamp (workspace:GetServerTimeNow() space) to
-- the client's local os.clock() space using the current smoothed offset.
-- Returns the server timestamp unmodified if no offset has been measured yet.
function DriftCorrector.ToLocalClock(self: any, ServerTime: number): number
	local Offset = self._ClockOffset
	if not Offset then
		-- No offset measured yet. Seed from this sample and return raw.
		self._ClockOffset = workspace:GetServerTimeNow() - os.clock()
		return ServerTime - self._ClockOffset
	end
	return ServerTime - Offset
end

-- Returns the current smoothed clock offset in seconds, or 0 if not yet measured.
function DriftCorrector.GetOffset(self: any): number
	return self._ClockOffset or 0
end

-- Idempotent destroy.
function DriftCorrector.Destroy(self: any)
	if self._Destroyed then return end
	self._Destroyed = true
	setmetatable(self, nil)
end

-- ─── Module Return ────────────────────────────────────────────────────────────

return table.freeze(setmetatable(DriftCorrector, {
	__index = function(_, Key)
		Logger:Warn(string_format("DriftCorrector: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, _Value)
		Logger:Error(string_format("DriftCorrector: write to protected key '%s'", tostring(Key)))
	end,
}))
