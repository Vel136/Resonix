--!native
--!optimize 2
--!strict

--[[
	ResonixNet/Transport/StateBatcher.lua

	Collects all currently active emissions from the Resonix buffer and
	packs them into a single state batch buffer for late-join sync.

	Unlike VetraNet's StateBatcher which runs every frame (to stream bullet
	positions), Resonix's StateBatcher is called ONLY on PlayerAdded because
	sound emissions are static — their position doesn't change after emission.
	The client can reconstruct the full emission state from a single snapshot:
	position, preset, and the server-clock timestamps for EmittedAt/ExpiresAt.

	The "central performance claim" here is different from VetraNet's: instead
	of per-frame replication, we pay a one-time joining cost per player to
	ensure they hear long-duration ambient sounds (vending machines, power
	nodes, helicopter approach) that were already active when they arrived.

	Collect() reads from the Resonix instance's buffer, which is the ONE
	place in ResonixNet that directly accesses internal Resonix state.
]]

local Identity     = "StateBatcher"

local StateBatcher = {}
StateBatcher.__type = Identity

local StateBatcherMetatable = table.freeze({ __index = StateBatcher })

-- ─── References ──────────────────────────────────────────────────────────────

local Transport = script.Parent
local Core      = script.Parent.Parent.Core

-- ─── Module References ───────────────────────────────────────────────────────

local Constants  = require(Transport.Constants)
local Serializer = require(Transport.Serializer)
local LogService = require(Core.Logger)

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, false)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local table_create  = table.create
local table_clear   = table.clear
local string_format = string.format

-- ─── Factory ─────────────────────────────────────────────────────────────────

function StateBatcher.new(): any
	return setmetatable({
		-- Monotonically increasing frame counter stamped on each batch.
		-- Clients discard batches with FrameId <= their last received FrameId,
		-- preventing reordered packets from replaying stale state.
		_FrameId = 0,

		-- Pre-allocated state entry array written by Collect() and read by Build().
		_StateBuffer = table_create(Constants.MAX_STATE_BATCH_SIZE),
		_StateCount  = 0,
	}, StateBatcherMetatable)
end

-- ─── API ─────────────────────────────────────────────────────────────────────

-- Collect all currently active emissions from the Resonix buffer into the
-- pre-allocated _StateBuffer. Returns the number of entries collected.
-- Called once when a player joins — not every frame.
--
-- PresetRegistry is required to map each emission's PresetKey back to its
-- numeric hash for compact wire encoding. Emissions with no registered
-- preset hash are skipped — the client would have no way to reconstruct them.
function StateBatcher.Collect(self: any, Resonix: any, PresetRegistry_: any)
	local Count = 0
	local StateBuffer  = self._StateBuffer
	local MaxBatchSize = Constants.MAX_STATE_BATCH_SIZE
	local ServerNow    = workspace:GetServerTimeNow()

	for _, Emission in Resonix:GetActiveEmissions() do
		if Count >= MaxBatchSize then
			Logger:Warn(string_format(
				"StateBatcher.Collect: active emissions exceed MAX_STATE_BATCH_SIZE (%d) — excess skipped",
				MaxBatchSize
			))
			break
		end

		local PresetHash = Emission.PresetKey and PresetRegistry_:HashOf(Emission.PresetKey)
		if not PresetHash then
			-- Emission was created with a preset that isn't registered in the
			-- PresetRegistry (e.g. emitted directly via Resonix:Emit). Skip it.
			continue
		end

		-- Convert os.clock() timestamps to server-clock space so the client can
		-- reconstruct ExpiresAt correctly regardless of clock drift.
		-- ServerNow - os.clock() = offset from local clock to server clock.
		local ClockOffset     = ServerNow - os.clock()
		local ServerEmittedAt = Emission.EmittedAt + ClockOffset
		local ServerExpiresAt = Emission.ExpiresAt + ClockOffset

		Count += 1
		local Entry = StateBuffer[Count]
		if Entry then
			Entry.ServerEmissionId = Emission.__netId or 0
			Entry.PresetHash       = PresetHash
			Entry.Position         = Emission.Position
			Entry.ServerEmittedAt  = ServerEmittedAt
			Entry.ServerExpiresAt  = ServerExpiresAt
		else
			StateBuffer[Count] = {
				ServerEmissionId = Emission.__netId or 0,
				PresetHash       = PresetHash,
				Position         = Emission.Position,
				ServerEmittedAt  = ServerEmittedAt,
				ServerExpiresAt  = ServerExpiresAt,
			}
		end
	end

	self._StateCount = Count
end

-- Encode the collected state into a buffer and reset the collection.
-- Returns the encoded buffer.
function StateBatcher.Build(self: any): buffer
	self._FrameId += 1
	local Encoded = Serializer.EncodeStateBatch(self._FrameId, self._StateBuffer, self._StateCount)

	-- Zero out used entries so GC can collect Vector3 values from the snapshot.
	for i = 1, self._StateCount do
		local Entry = self._StateBuffer[i]
		if Entry then
			Entry.ServerEmissionId = 0
			Entry.PresetHash       = 0
			Entry.Position         = Vector3.zero
			Entry.ServerEmittedAt  = 0
			Entry.ServerExpiresAt  = 0
		end
	end
	self._StateCount = 0

	return Encoded
end

-- Returns the FrameId that the next Build() call will assign.
-- Used by LateJoinHandler to stamp its batch with a coherent FrameId
-- so the client doesn't discard the first regular batch as already-seen.
function StateBatcher.GetNextFrameId(self: any): number
	return self._FrameId + 1
end

-- Idempotent destroy.
function StateBatcher.Destroy(self: any)
	if self._Destroyed then return end
	self._Destroyed = true
	table_clear(self._StateBuffer)
	self._StateBuffer = nil
	setmetatable(self, nil)
end

-- ─── Module Return ────────────────────────────────────────────────────────────

return table.freeze(setmetatable(StateBatcher, {
	__index = function(_, Key)
		Logger:Warn(string_format("StateBatcher: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, _Value)
		Logger:Error(string_format("StateBatcher: write to protected key '%s'", tostring(Key)))
	end,
}))
