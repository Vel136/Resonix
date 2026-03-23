--!native
--!optimize 2
--!strict

--[[
	SoundBuffer
	
	Persistence and lifecycle layer for active sound emissions.
	
	The buffer solves a fundamental problem: the perception service polls
	at discrete intervals (every 0.1 seconds), but sound events happen
	at arbitrary moments in continuous time. An instantaneous event like
	a gunshot that fires at t=0.05 must still be detectable when perception
	runs at t=0.1, t=0.2, and potentially t=0.3.
	
	The solution is a relevance window — each emission persists in the
	buffer for longer than its physical duration, giving every polling
	consumer enough time to observe it. A gunshot with a 0.05s physical
	duration stays in the buffer for 0.05 + 0.6 = 0.65 seconds total,
	ensuring it's seen by at least six consecutive perception ticks.
]]

local SoundTypes = require(script.Parent.SoundTypes)

type SoundEmission = SoundTypes.SoundEmission

-- ─── Module ──────────────────────────────────────────────────────────────────

local SoundBuffer   = {}
SoundBuffer.__index = SoundBuffer
SoundBuffer.__type  = "SoundBuffer"

-- ─── Constants ───────────────────────────────────────────────────────────────

-- How long an emission persists beyond its physical duration.
-- This window ensures that fast-polling consumers (perception at 0.1s)
-- never miss an instantaneous event regardless of when within its
-- physical duration the event was emitted relative to a poll cycle.
local DECAY_WINDOW = 0.6  -- seconds

-- Maximum number of simultaneous active emissions.
-- Beyond this, the oldest emission is evicted to make room.
-- 128 covers: 30 AI footsteps + 12 player footsteps + weapon fire
-- + impacts + environment sounds with headroom.
local MAX_EMISSIONS = 128

-- Cleanup interval — how often the background task prunes expired emissions.
-- 0.5 seconds is frequent enough to keep the buffer lean without spending
-- significant CPU time on maintenance.
local PRUNE_INTERVAL = 0.5

-- ─── Types ───────────────────────────────────────────────────────────────────

export type SoundBuffer = typeof(setmetatable({} :: {
	-- Primary storage: Id → emission for O(1) lookup and cancellation
	_active      : { [string]: SoundEmission },

	-- Expiry queue: sorted ascending by ExpiresAt for O(1) pruning
	-- Only the front needs to be checked during each prune pass.
	_expiryQueue : { SoundEmission },

	-- Count tracks _active size to avoid iterating it for MAX check
	_count       : number,

	_pruneTask   : thread?,
	_destroyed   : boolean,
}, { __index = SoundBuffer }))

-- ─── Constructor ─────────────────────────────────────────────────────────────

function SoundBuffer.new(): SoundBuffer
	local self = setmetatable({} :: any, { __index = SoundBuffer })

	self._active      = {}
	self._expiryQueue = {}
	self._count       = 0
	self._destroyed   = false

	-- Background prune task runs independently of the game loop.
	-- It doesn't need to run every frame — emissions expiring 0.5s
	-- late doesn't meaningfully affect gameplay.
	self._pruneTask = task.spawn(function()
		while not self._destroyed do
			task.wait(PRUNE_INTERVAL)
			if not self._destroyed then
				self:_PruneExpired()
			end
		end
	end)

	return self
end

-- ─── Emit ────────────────────────────────────────────────────────────────────

--[[
	Stores an emission in the buffer.
	
	Called by the Emitter after constructing a SoundEmission.
	The emission must already have EmittedAt and ExpiresAt set.
	
	If the buffer is at capacity, the oldest emission (front of
	the expiry queue) is evicted to make room. This prioritizes
	recent events over old ones, which is the correct behavior —
	a gunshot fired now matters more than a vending machine hum
	from 55 seconds ago that's almost expired anyway.
	
	@param emission  SoundEmission  A fully constructed emission.
]]
function SoundBuffer.Store(self: SoundBuffer, emission: SoundEmission)
	-- Evict oldest if at capacity
	if self._count >= MAX_EMISSIONS then
		local oldest = self._expiryQueue[1]
		if oldest then
			table.remove(self._expiryQueue, 1)
			self._active[oldest.Id] = nil
			self._count            -= 1
		end
	end

	-- Store in primary dictionary
	self._active[emission.Id] = emission
	self._count              += 1

	-- Insert into expiry queue maintaining ascending sort by ExpiresAt.
	-- Binary search for correct insertion position.
	local queue = self._expiryQueue
	local lo, hi = 1, #queue
	local insertAt = #queue + 1

	while lo <= hi do
		local mid = math.floor((lo + hi) / 2)
		if queue[mid].ExpiresAt <= emission.ExpiresAt then
			lo       = mid + 1
		else
			insertAt = mid
			hi       = mid - 1
		end
	end

	table.insert(queue, insertAt, emission)
end

-- ─── Cancel ──────────────────────────────────────────────────────────────────

--[[
	Immediately removes an emission from the buffer before it naturally expires.
	
	Used when a persistent sound source stops mid-emission — for example,
	when a player is killed while channeling a vending machine, or when
	the power node interaction is interrupted. Without cancellation, the
	emission would continue attracting AI for its full duration even though
	the source sound has stopped.
	
	The expiry queue entry is NOT removed here for performance — it will
	be found as a nil entry during the next prune pass and skipped.
	Removing from the middle of the sorted array would be O(n).
	
	@param emissionId  string  The Id of the emission to cancel.
	@return boolean  True if found and cancelled, false if not found.
]]
function SoundBuffer.Cancel(self: SoundBuffer, emissionId: string): boolean
	if not self._active[emissionId] then return false end

	self._active[emissionId] = nil
	self._count             -= 1
	return true
end

-- ─── Query ───────────────────────────────────────────────────────────────────

--[[
	Returns an iterator over all active emissions within maxRadius studs
	of the given position.
	
	This is the ONLY iteration interface. External systems — the Propagator,
	the Query Interface — call this rather than accessing _active directly.
	
	The radius filter uses squared distance to avoid the sqrt() call for
	emissions that are clearly out of range. The sqrt() is only computed
	for emissions that pass the squared distance check, which in practice
	is a small fraction of the active set.
	
	Note: maxRadius here is a spatial pre-filter only. The actual emission
	radius (emission.Radius) may be smaller — the Propagator handles that
	correctly in its distance falloff calculation. This function just
	avoids passing obviously-out-of-range emissions to the Propagator.
	
	@param position   Vector3  The listener's world position.
	@param maxRadius  number   Maximum distance to consider, in studs.
	@return iterator  Yields SoundEmission objects within range.
]]
function SoundBuffer.	(
	self      : SoundBuffer,
	position  : Vector3,
	maxRadius : number
): () -> SoundEmission?
	local active   = self._active
	local radiusSq = maxRadius * maxRadius
	local px, py, pz = position.X, position.Y, position.Z

	-- Collect matching emissions into a snapshot array.
	-- We snapshot rather than iterate live because the Propagator may
	-- yield (it spawns raycasts) and the active table could change
	-- during iteration if we iterated directly.
	local snapshot: { SoundEmission } = {}

	for _, emission in active do
		local dx = emission.Position.X - px
		local dy = emission.Position.Y - py
		local dz = emission.Position.Z - pz
		local dsq = dx*dx + dy*dy + dz*dz

		if dsq <= radiusSq then
			table.insert(snapshot, emission)
		end
	end

	-- Return a stateful iterator over the snapshot
	local index = 0
	return function(): SoundEmission?
		index += 1
		return snapshot[index]
	end
end

--[[
	Returns the total number of active emissions in the buffer.
	Useful for performance monitoring and debug display.
]]
function SoundBuffer.GetCount(self: SoundBuffer): number
	return self._count
end

--[[
	Returns true if an emission with this Id is currently active.
]]
function SoundBuffer.IsActive(self: SoundBuffer, emissionId: string): boolean
	return self._active[emissionId] ~= nil
end

-- ─── Internal: Pruning ───────────────────────────────────────────────────────

--[[
	Removes all expired emissions from the buffer.
	
	The expiry queue is sorted ascending by ExpiresAt, so we only need
	to check the front. The moment we find an entry that hasn't expired,
	everything after it is guaranteed to also not have expired.
	
	Entries that were cancelled (present in queue but nil in _active)
	are silently skipped — they were already removed from _active by
	Cancel() and just need to be cleared from the queue here.
	
	Called by the background task every PRUNE_INTERVAL seconds.
]]
function SoundBuffer._PruneExpired(self: SoundBuffer)
	local now   = os.clock()
	local queue = self._expiryQueue

	while #queue > 0 do
		local front = queue[1]

		-- Stop as soon as we find an entry that hasn't expired
		if front.ExpiresAt > now then break end

		table.remove(queue, 1)

		-- Only decrement count if this entry was still in _active
		-- (it might have been cancelled already)
		if self._active[front.Id] then
			self._active[front.Id] = nil
			self._count           -= 1
		end
	end
end

-- ─── Lifecycle ───────────────────────────────────────────────────────────────

function SoundBuffer.Destroy(self: SoundBuffer)
	if self._destroyed then return end
	self._destroyed = true

	if self._pruneTask then
		task.cancel(self._pruneTask)
		self._pruneTask = nil
	end

	table.clear(self._active)
	table.clear(self._expiryQueue)
	self._count = 0
end

return SoundBuffer
