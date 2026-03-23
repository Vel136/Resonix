--[=[
	@class SoundBuffer

	Persistence and lifecycle layer for active sound emissions.

	The buffer solves a fundamental problem: any polling consumer calls
	`:QueryPosition()` at discrete intervals, but sound events happen at
	arbitrary moments in continuous time. An instantaneous event like a
	gunshot that fires at `t = 0.05` must still be detectable when a query
	runs at `t = 0.1`, `t = 0.2`, and potentially `t = 0.3`.

	The solution is a relevance window — each emission persists in the buffer
	for longer than its physical duration:

	```
	ExpiresAt = EmittedAt + Duration + DECAY_WINDOW (0.6s)
	```

	A gunshot with a 0.05s physical duration stays in the buffer for 0.65s
	total, ensuring it is visible to at least six consecutive 0.1s query ticks.

	SoundBuffer is managed internally by [Resonix] and does not need to be
	constructed directly.
]=]
local SoundBuffer = {}

-- ─── Factory ─────────────────────────────────────────────────────────────────

--[=[
	Creates a new SoundBuffer and starts its background prune task.

	The prune task runs every 0.5 seconds and removes expired emissions from
	the buffer and expiry queue. It is cancelled on `:Destroy()`.

	@return SoundBuffer
]=]
function SoundBuffer.new(): SoundBuffer end

-- ─── Emit ────────────────────────────────────────────────────────────────────

--[=[
	Stores an emission in the buffer.

	The emission must already have `EmittedAt` and `ExpiresAt` set. If the
	buffer is at its 128-emission capacity, the oldest emission (earliest
	`ExpiresAt`) is evicted to make room.

	@param emission SoundEmission -- A fully constructed emission.
]=]
function SoundBuffer:Store(emission: SoundEmission) end

-- ─── Cancel ──────────────────────────────────────────────────────────────────

--[=[
	Immediately removes an emission from the active set.

	The emission disappears from all subsequent `:IterateNear()` results.
	The expiry queue entry is left in place for performance — it will be
	skipped silently during the next prune pass.

	Returns `true` if the emission was found and removed, `false` if it was
	not in the active set (already expired or never stored).

	@param emissionId string -- The `Id` of the emission to cancel.
	@return boolean
]=]
function SoundBuffer:Cancel(emissionId: string): boolean end

-- ─── Query ───────────────────────────────────────────────────────────────────

--[=[
	Returns a stateful iterator over all active emissions within `maxRadius`
	studs of `position`.

	The iteration is over a snapshot taken at call time — the active table
	can change safely during iteration.

	```lua
	for emission in buffer:IterateNear(listenerPos, 500) do
	    -- process emission
	end
	```

	@param position Vector3 -- The listener's world position.
	@param maxRadius number -- Maximum distance to consider, in studs.
	@return () -> SoundEmission? -- Iterator that yields SoundEmission objects within range.
]=]
function SoundBuffer:IterateNear(position: Vector3, maxRadius: number): () -> SoundEmission? end

--[=[
	Returns the total number of active emissions currently in the buffer.

	@return number
]=]
function SoundBuffer:GetCount(): number end

--[=[
	Returns `true` if an emission with the given ID is currently active.

	@param emissionId string
	@return boolean
]=]
function SoundBuffer:IsActive(emissionId: string): boolean end

-- ─── Lifecycle ───────────────────────────────────────────────────────────────

--[=[
	Destroys the buffer, cancels the prune task, and clears all emissions.

	Idempotent — safe to call twice.
]=]
function SoundBuffer:Destroy() end

return SoundBuffer
