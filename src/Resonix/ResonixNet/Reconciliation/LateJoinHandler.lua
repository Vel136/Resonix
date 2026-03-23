--!native
--!optimize 2
--!strict

--[[
	ResonixNet/Reconciliation/LateJoinHandler.lua

	Sends the full active-emission state to a player who joins while
	long-duration emissions are already running.

	Without this module, a player who joins mid-match hears nothing from
	the ambient environment until new emissions fire after their arrival.
	They would miss:
	  - A VendingMachine (60s) that's been active for 45 seconds
	  - A PowerNode (25s) interaction near their spawn
	  - A Helicopter_Approach (long-range, huge radius) already audible

	LateJoinHandler sends a CHANNEL_STATE batch through OutboundBatcher and
	flushes it immediately — the joining client reconstructs all active
	emissions from the snapshot and applies them to their local SoundBuffer
	with correct remaining durations.

	The snapshot uses server-clock timestamps so the client can compute
	how much lifetime each emission has left in local os.clock() space
	via ClockDriftCorrector.

	SERVER-ONLY. Errors at require() time if loaded on the client.
]]

local Identity        = "LateJoinHandler"

local LateJoinHandler = {}
LateJoinHandler.__type = Identity

-- ─── References ──────────────────────────────────────────────────────────────

local Core      = script.Parent.Parent.Core
local Transport = script.Parent.Parent.Transport

-- ─── Module References ───────────────────────────────────────────────────────

local Authority        = require(Core.Authority)
local LogService       = require(Core.Logger)
local StateBatcher     = require(Transport.StateBatcher)

Authority.AssertServer("LateJoinHandler")

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, false)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local string_format = string.format

-- ─── API ─────────────────────────────────────────────────────────────────────

-- Send a full state snapshot to the joining player.
-- Must be called via OutboundBatcher to include the correct channel prefix —
-- calling Remote:FireClient directly would send a raw buffer with no prefix,
-- causing the client decoder to misidentify the first payload byte as a channel.
--
-- Batcher:Flush(Remote) is called immediately after writing so the snapshot
-- arrives on the same tick as the join, not deferred until the next Heartbeat.
function LateJoinHandler.SyncPlayer(
	Player          : Player,
	Resonix         : any,
	PresetRegistry_ : any,
	OutboundBatcher_: any,
	Remote          : RemoteEvent
)
	-- Build the snapshot using a throwaway StateBatcher instance.
	-- We don't use the shared StateBatcher because it belongs to the
	-- every-frame state pipeline and its FrameId must stay coherent with
	-- the ongoing stream. A fresh instance with FrameId=1 is fine for
	-- the one-shot late-join batch — the client initialises LastFrameId
	-- to 0, so any FrameId > 0 will be accepted.
	local Batcher = StateBatcher.new()
	Batcher:Collect(Resonix, PresetRegistry_)

	if Batcher._StateCount == 0 then
		Batcher:Destroy()
		return
	end

	local Encoded = Batcher:Build()
	Batcher:Destroy()

	OutboundBatcher_:WriteStateForPlayer(Player, Encoded)

	-- Flush immediately to this player only.
	-- We do NOT flush the full OutboundBatcher here because that would
	-- prematurely send every other player's mid-frame accumulated messages.
	-- Instead we use the Batcher's single-player path and flush only the
	-- joining player's cursor by calling Flush with a wrapped FireClient.
	--
	-- The simplest correct approach: call FireClient directly for the joining
	-- player's cursor, which we just wrote. Retrieve the cursor and send it.
	-- This is the ONE permitted exception to "Flush is the only FireClient caller".
	local Cursor = OutboundBatcher_._Cursors[Player]
	if Cursor and Cursor.Offset > 0 and Player.Parent then
		local ExactBuf = buffer.create(Cursor.Offset)
		buffer.copy(ExactBuf, 0, Cursor.Buffer, 0, Cursor.Offset)
		Remote:FireClient(Player, ExactBuf)
		Cursor.Offset = 0
	end

	Logger:Debug(string_format(
		"LateJoinHandler: synced state batch to '%s'",
		Player.Name
	))
end

-- ─── Module Return ────────────────────────────────────────────────────────────

return table.freeze(setmetatable(LateJoinHandler, {
	__index = function(_, Key)
		Logger:Warn(string_format("LateJoinHandler: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, _Value)
		Logger:Error(string_format("LateJoinHandler: write to protected key '%s'", tostring(Key)))
	end,
}))
