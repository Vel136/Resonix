--!strict

--[[
	ResonixNet/Transport/Constants.lua

	All network configuration constants for ResonixNet.

	Channel IDs for the single-remote batched protocol:
	  CHANNEL_EMIT   (0) — server replicating a new emission to clients
	  CHANNEL_CANCEL (1) — server cancelling an active emission on clients
	  CHANNEL_STATE  (2) — full active-emission state dump (late-join sync)

	One RemoteEvent carries all three channel types. Each message in the
	batched buffer begins with a 1-byte channel prefix, then a 2-byte u16
	length, then the encoded payload.
]]

local Constants = table.freeze({
	-- ── Remote naming ─────────────────────────────────────────────────────
	NETWORK_FOLDER_NAME = "ResonixNet",
	REMOTE_EMISSION     = "EmissionChannel",

	-- ── Batched protocol channels ──────────────────────────────────────────
	CHANNEL_EMIT   = 0,
	CHANNEL_CANCEL = 1,
	CHANNEL_STATE  = 2,

	-- ── Outbound batcher ───────────────────────────────────────────────────
	OUTBOUND_BUFFER_INITIAL = 256,
	OUTBOUND_BUFFER_MAX     = 16384,  -- 16 KB hard ceiling per player per frame

	-- ── State batch ────────────────────────────────────────────────────────
	MAX_STATE_BATCH_SIZE = 128,

	-- ── Rate limiting defaults ─────────────────────────────────────────────
	DEFAULT_TOKENS_PER_SECOND  = 20,
	DEFAULT_BURST_LIMIT        = 40,

	-- ── Validation defaults ────────────────────────────────────────────────
	DEFAULT_MAX_ORIGIN_TOLERANCE = 15,

	-- ── Session defaults ───────────────────────────────────────────────────
	DEFAULT_MAX_CONCURRENT_EMITS = 12,

	-- ── Reconciliation defaults ────────────────────────────────────────────
	DEFAULT_CLOCK_SYNC_RATE = 5.0,
})

return Constants
