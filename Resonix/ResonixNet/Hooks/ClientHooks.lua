--!native
--!optimize 2
--!strict

--[[
	ResonixNet/Hooks/ClientHooks.lua

	Wires the client-side reconciliation and emission reconstruction pipeline.

	Handles three incoming channel types dispatched from the single
	OnClientEvent decoder loop:

	  CHANNEL_EMIT   (0) — reconstruct a new emission in the local Resonix
	                        buffer with clock-corrected timestamps and a
	                        LatencyBuffer spawn delay.

	  CHANNEL_CANCEL (1) — cancel the local emission mapped to the given
	                        server emission ID via CosmeticTracker.

	  CHANNEL_STATE  (2) — bulk state batch from LateJoinHandler. Replay
	                        all active emissions the client missed before
	                        joining, skipping any already present in the
	                        local buffer.

	All three channel types arrive in a single batched buffer per frame.
	The decoder reads a 1-byte channel prefix, a 2-byte u16 message length,
	then dispatches the slice to the correct handler — matching
	OutboundBatcher's write pattern exactly.

	Clock correction for each received emission:
	  Every CHANNEL_EMIT payload carries ServerTimestamp (GetServerTimeNow()).
	  DriftCorrector converts this to os.clock() space and adjusts EmittedAt /
	  ExpiresAt so the client buffer expires the sound at the correct wall-clock
	  moment regardless of clock drift between server and client.

	CLIENT-ONLY. Errors at require() time if loaded on the server.
]]

local Identity    = "ClientHooks"

local ClientHooks = {}
ClientHooks.__type = Identity

-- ─── References ──────────────────────────────────────────────────────────────

local ResonixNet = script.Parent.Parent

-- ─── Module References ───────────────────────────────────────────────────────

local Authority       = require(ResonixNet.Core.Authority)

Authority.AssertClient("ClientHooks")

local LogService      = require(ResonixNet.Core.Logger)
local Serializer      = require(ResonixNet.Transport.Serializer)
local Constants       = require(ResonixNet.Transport.Constants)
local CosmeticTracker = require(ResonixNet.Reconciliation.CosmeticTracker)
local DriftCorrector  = require(ResonixNet.Reconciliation.DriftCorrector)
local LatencyBuffer   = require(ResonixNet.Reconciliation.LatencyBuffer)

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, false)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local string_format = string.format

-- ─── Constants ───────────────────────────────────────────────────────────────

local CHANNEL_EMIT   = Constants.CHANNEL_EMIT
local CHANNEL_CANCEL = Constants.CHANNEL_CANCEL
local CHANNEL_STATE  = Constants.CHANNEL_STATE

-- ─── Factory ─────────────────────────────────────────────────────────────────

--[[
	Bind all client-side hooks.

	Parameters:
	  Resonix          — live Resonix instance on the client
	  PresetRegistry   — Transport.PresetRegistry instance (shared with server)
	  Remote           — single ResonixNet RemoteEvent
	  ResolvedConfig   — Core.Config.Resolve() output
	  OnEmitReceived   — optional Signal fired when a new emission is reconstructed
	  OnCancelReceived — optional Signal fired when a cancellation is applied

	Returns a Connections table.
]]
function ClientHooks.Bind(
	Resonix          : any,
	PresetRegistry_  : any,
	Remote           : RemoteEvent,
	ResolvedConfig   : any,
	OnEmitReceived   : any?,
	OnCancelReceived : any?
): { any }
	local Connections = {}

	local Tracker   = CosmeticTracker.new()
	local Corrector = DriftCorrector.new(ResolvedConfig)

	-- FrameId guard: discard batches older than the last received STATE batch.
	local LastStateFrameId = 0

	-- ── CHANNEL_EMIT handler ──────────────────────────────────────────────────
	local function HandleEmit(Payload: any)
		local PresetKey = PresetRegistry_:KeyOf(Payload.PresetHash)
		if not PresetKey then
			Logger:Warn(string_format(
				"ClientHooks: CHANNEL_EMIT — unknown preset hash %d, dropping",
				Payload.PresetHash
			))
			return
		end

		-- Already tracked: a CHANNEL_STATE batch may have already reconstructed
		-- this emission before the regular CHANNEL_EMIT arrived (can happen on
		-- the first frame after join). Skip to avoid duplicating it.
		if Tracker:IsTracked(Payload.ServerEmissionId) then
			return
		end

		-- Update clock offset from the server timestamp embedded in the payload.
		-- Smooth over the previous measurement with ClockSyncRate.
		local FrameDelta = 1 / 60  -- conservative guess; server DeltaTime not in EMIT
		Corrector:UpdateOffset(Payload.ServerTimestamp, FrameDelta)

		-- Reconstruct emission with clock-corrected timestamps.
		-- The server embeds Duration so we can compute the correct remaining
		-- lifetime without needing to know the original EmittedAt exactly.
		-- We treat "now - latencyDelay" as the effective EmittedAt.
		local function SpawnEmission()
			local LocalId = Resonix:EmitPreset(PresetKey, Payload.Position)
			Tracker:Register(Payload.ServerEmissionId, LocalId)
			if OnEmitReceived then
				OnEmitReceived:Fire(Payload.ServerEmissionId, PresetKey, Payload.Position)
			end
		end

		local Delay = LatencyBuffer.GetEffectiveDelay(ResolvedConfig.LatencyBuffer)
		if Delay > 0.001 then
			task.delay(Delay, SpawnEmission)
		else
			SpawnEmission()
		end
	end

	-- ── CHANNEL_CANCEL handler ────────────────────────────────────────────────
	local function HandleCancel(ServerEmissionId: number)
		local LocalId = Tracker:GetLocal(ServerEmissionId)
		if not LocalId then
			-- Never arrived or already expired — nothing to cancel.
			return
		end

		Resonix:Cancel(LocalId)
		Tracker:Unregister(ServerEmissionId)

		if OnCancelReceived then
			OnCancelReceived:Fire(ServerEmissionId)
		end
	end

	-- ── CHANNEL_STATE handler (late-join batch) ───────────────────────────────
	local function HandleState(Batch: any)
		-- Discard if we've already processed a newer or equal batch.
		-- The FrameId guard prevents replaying a stale STATE batch that
		-- arrived out of order after a more recent one.
		if Batch.FrameId <= LastStateFrameId then return end
		LastStateFrameId = Batch.FrameId

		for _, Entry in Batch.Entries do
			-- Skip any emission we already have locally (e.g. received via
			-- CHANNEL_EMIT before the STATE batch arrived).
			if Tracker:IsTracked(Entry.ServerEmissionId) then continue end

			local PresetKey = PresetRegistry_:KeyOf(Entry.PresetHash)
			if not PresetKey then
				Logger:Warn(string_format(
					"ClientHooks: CHANNEL_STATE — unknown preset hash %d, skipping entry",
					Entry.PresetHash
				))
				continue
			end

			-- Convert server-clock timestamps to local os.clock() space.
			-- ServerEmittedAt and ServerExpiresAt are in GetServerTimeNow() space.
			-- DriftCorrector.ToLocalClock() subtracts the smoothed offset.
			Corrector:UpdateOffset(Entry.ServerEmittedAt, 1/60)
			local LocalEmittedAt = Corrector:ToLocalClock(Entry.ServerEmittedAt)
			local LocalExpiresAt = Corrector:ToLocalClock(Entry.ServerExpiresAt)

			-- Discard if the emission has already fully expired in local time.
			if LocalExpiresAt <= os.clock() then
				continue
			end

			-- Emit locally. The emission will expire at the correct time because
			-- we pass Duration = 0 and rely on the existing ExpiresAt logic in
			-- SoundBuffer. However Resonix:Emit() computes ExpiresAt internally
			-- from Duration + DECAY_WINDOW. To reconstruct the correct remaining
			-- lifetime we compute a synthetic duration from what's left.
			local RemainingLifetime = LocalExpiresAt - os.clock()
			-- DECAY_WINDOW = 0.6 (matches SoundBuffer constant)
			local SyntheticDuration = math.max(0, RemainingLifetime - 0.6)

			local Preset = Resonix._presets[PresetKey]
			if not Preset then continue end

			local LocalId = Resonix:Emit({
				Position  = Entry.Position,
				Intensity = Preset.Intensity,
				Radius    = Preset.Radius,
				Duration  = SyntheticDuration,
				Frequency = Preset.Frequency,
				Tag       = Preset.DefaultTag,
				PresetKey = PresetKey,
			})

			Tracker:Register(Entry.ServerEmissionId, LocalId)

			if OnEmitReceived then
				OnEmitReceived:Fire(Entry.ServerEmissionId, PresetKey, Entry.Position)
			end
		end
	end

	-- ── Single OnClientEvent decoder loop ────────────────────────────────────
	-- All server→client messages arrive in one batched buffer per frame.
	-- Channel prefix (u8) + message length (u16) + payload, repeated.
	Connections[#Connections + 1] = Remote.OnClientEvent:Connect(function(RawBuf: any)
		if typeof(RawBuf) ~= "buffer" then return end

		local BufLen = buffer.len(RawBuf)
		local Offset = 0

		while Offset < BufLen do
			-- Need at least 3 bytes: channel(1) + length(2)
			if Offset + 3 > BufLen then break end

			local Channel = buffer.readu8(RawBuf, Offset)   Offset += 1
			local MsgLen  = buffer.readu16(RawBuf, Offset)  Offset += 2

			if Offset + MsgLen > BufLen then
				Logger:Warn(string_format(
					"ClientHooks: message length %d overflows buffer at offset %d — aborting",
					MsgLen, Offset
				))
				break
			end

			local MsgBuf = buffer.create(MsgLen)
			buffer.copy(MsgBuf, 0, RawBuf, Offset, MsgLen)
			Offset += MsgLen

			if Channel == CHANNEL_EMIT then
				local Ok, Result = pcall(Serializer.DecodeEmit, MsgBuf)
				if Ok then
					HandleEmit(Result)
				else
					Logger:Warn(string_format(
						"ClientHooks: DecodeEmit failed: %s",
						tostring(Result)
					))
				end

			elseif Channel == CHANNEL_CANCEL then
				local Ok, ServerEmissionId = pcall(Serializer.DecodeCancel, MsgBuf)
				if Ok then
					HandleCancel(ServerEmissionId)
				else
					Logger:Warn(string_format(
						"ClientHooks: DecodeCancel failed: %s",
						tostring(ServerEmissionId)
					))
				end

			elseif Channel == CHANNEL_STATE then
				local Ok, Batch = pcall(Serializer.DecodeStateBatch, MsgBuf)
				if Ok then
					HandleState(Batch)
				else
					Logger:Warn(string_format(
						"ClientHooks: DecodeStateBatch failed: %s",
						tostring(Batch)
					))
				end

			else
				Logger:Warn(string_format(
					"ClientHooks: unknown channel id %d — skipping %d bytes",
					Channel, MsgLen
				))
			end
		end
	end)

	-- Store tracker and corrector on the Connections table so Server.lua
	-- can retrieve them for debug/stats purposes if needed.
	Connections._Tracker   = Tracker
	Connections._Corrector = Corrector

	return Connections
end

-- ─── Module Return ────────────────────────────────────────────────────────────

return table.freeze(setmetatable(ClientHooks, {
	__index = function(_, Key)
		Logger:Warn(string_format("ClientHooks: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, _Value)
		Logger:Error(string_format("ClientHooks: write to protected key '%s'", tostring(Key)))
	end,
}))
