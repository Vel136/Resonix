--!native
--!optimize 2
--!strict

--[[
	ResonixNet/Transport/OutboundBatcher.lua

	Per-player outbound cursor accumulator.

	Replaces per-event RemoteEvent sends with a single buffer per player
	flushed once per Heartbeat. Every message gets a 1-byte channel prefix
	(CHANNEL_EMIT, CHANNEL_CANCEL, CHANNEL_STATE) followed by a 2-byte u16
	length, then the payload. The client decoder reads the prefix and
	dispatches in a tight loop until the buffer is exhausted.

	Write pattern (server, per event):
	    Batcher:WriteEmitForAll(AllPlayers, EncodedEmitBuf)
	    Batcher:WriteCancelForAll(AllPlayers, EncodedCancelBuf)
	    Batcher:WriteStateForPlayer(Player, EncodedStateBuf)  -- late-join only

	Flush pattern (server, once per Heartbeat):
	    Batcher:Flush(Remote)  — one FireClient per player with their
	                             accumulated buffer, then resets all cursors.

	No allocations in the steady state. Each cursor's buffer doubles on
	overflow. Flush resets the write offset to 0, reusing the same memory.
	Flush is the ONLY place that calls Remote:FireClient.
]]

local Identity        = "OutboundBatcher"

local OutboundBatcher = {}
OutboundBatcher.__type = Identity

local OutboundBatcherMetatable = table.freeze({ __index = OutboundBatcher })

-- ─── References ──────────────────────────────────────────────────────────────

local Transport = script.Parent
local Core      = script.Parent.Parent.Core

-- ─── Module References ───────────────────────────────────────────────────────

local Constants  = require(Transport.Constants)
local LogService = require(Core.Logger)

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, false)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local buffer_len      = buffer.len
local buffer_create   = buffer.create
local buffer_writeu8  = buffer.writeu8
local buffer_writeu16 = buffer.writeu16
local buffer_copy     = buffer.copy
local table_clear     = table.clear
local string_format   = string.format

-- ─── Constants ───────────────────────────────────────────────────────────────

local CHANNEL_EMIT   = Constants.CHANNEL_EMIT
local CHANNEL_CANCEL = Constants.CHANNEL_CANCEL
local CHANNEL_STATE  = Constants.CHANNEL_STATE
local INITIAL_CAP    = Constants.OUTBOUND_BUFFER_INITIAL

-- ─── Cursor Helpers ──────────────────────────────────────────────────────────

local function NewCursor(): any
	local Buf = buffer_create(INITIAL_CAP)
	return {
		Buffer = Buf,
		Len    = INITIAL_CAP,
		Offset = 0,
		OutBuf = buffer_create(INITIAL_CAP),
		OutLen = INITIAL_CAP,
	}
end

local function Reserve(Cursor: any, Need: number)
	local Required = Cursor.Offset + Need
	if Required <= Cursor.Len then return end
	local NewLen = Cursor.Len
	while NewLen < Required do NewLen *= 2 end
	local NewBuf = buffer_create(NewLen)
	buffer_copy(NewBuf, 0, Cursor.Buffer, 0, Cursor.Offset)
	Cursor.Buffer = NewBuf
	Cursor.Len    = NewLen
end

local function WriteChannelByte(Cursor: any, Channel: number)
	Reserve(Cursor, 1)
	buffer_writeu8(Cursor.Buffer, Cursor.Offset, Channel)
	Cursor.Offset += 1
end

local function AppendMessage(Cursor: any, Message: buffer)
	local MessageLen = buffer_len(Message)
	Reserve(Cursor, 2 + MessageLen)
	buffer_writeu16(Cursor.Buffer, Cursor.Offset, MessageLen)
	Cursor.Offset += 2
	buffer_copy(Cursor.Buffer, Cursor.Offset, Message, 0, MessageLen)
	Cursor.Offset += MessageLen
end

-- ─── Factory ─────────────────────────────────────────────────────────────────

function OutboundBatcher.new(): any
	return setmetatable({
		_Cursors   = {} :: { [Player]: any },
		_Destroyed = false,
	}, OutboundBatcherMetatable)
end

-- ─── Write API ───────────────────────────────────────────────────────────────

-- Broadcast a new emission to every player.
function OutboundBatcher.WriteEmitForAll(
	self        : any,
	AllPlayers  : { Player },
	EncodedEmit : buffer
)
	for _, Player in AllPlayers do
		local Cursor = self._Cursors[Player]
		if not Cursor then
			Cursor = NewCursor()
			self._Cursors[Player] = Cursor
		end
		WriteChannelByte(Cursor, CHANNEL_EMIT)
		AppendMessage(Cursor, EncodedEmit)
	end
end

-- Send a new emission to a single player (e.g. server-authority emitter
-- that only one player should hear).
function OutboundBatcher.WriteEmitForPlayer(
	self        : any,
	Player      : Player,
	EncodedEmit : buffer
)
	local Cursor = self._Cursors[Player]
	if not Cursor then
		Cursor = NewCursor()
		self._Cursors[Player] = Cursor
	end
	WriteChannelByte(Cursor, CHANNEL_EMIT)
	AppendMessage(Cursor, EncodedEmit)
end

-- Broadcast a cancellation to every player.
function OutboundBatcher.WriteCancelForAll(
	self          : any,
	AllPlayers    : { Player },
	EncodedCancel : buffer
)
	for _, Player in AllPlayers do
		local Cursor = self._Cursors[Player]
		if not Cursor then
			Cursor = NewCursor()
			self._Cursors[Player] = Cursor
		end
		WriteChannelByte(Cursor, CHANNEL_CANCEL)
		AppendMessage(Cursor, EncodedCancel)
	end
end

-- Send a state batch to a single player (late-join sync).
-- Not used for every-frame broadcast — only for the one-shot join snapshot.
function OutboundBatcher.WriteStateForPlayer(
	self         : any,
	Player       : Player,
	EncodedState : buffer
)
	local Cursor = self._Cursors[Player]
	if not Cursor then
		Cursor = NewCursor()
		self._Cursors[Player] = Cursor
	end
	WriteChannelByte(Cursor, CHANNEL_STATE)
	AppendMessage(Cursor, EncodedState)
end

-- ─── Flush ───────────────────────────────────────────────────────────────────

-- Send each player's accumulated buffer as a single FireClient call.
-- Players with nothing queued this frame are skipped.
-- All cursor write offsets are reset to 0 after flushing.
function OutboundBatcher.Flush(self: any, Remote: RemoteEvent)
	for Player, Cursor in self._Cursors do
		if Cursor.Offset == 0 then continue end

		if Cursor.Offset > Cursor.OutLen then
			local NewLen = Cursor.OutLen
			while NewLen < Cursor.Offset do NewLen *= 2 end
			Cursor.OutBuf = buffer_create(NewLen)
			Cursor.OutLen = NewLen
		end

		buffer_copy(Cursor.OutBuf, 0, Cursor.Buffer, 0, Cursor.Offset)

		if Player.Parent then
			if Cursor.OutLen == Cursor.Offset then
				Remote:FireClient(Player, Cursor.OutBuf)
			else
				local ExactBuf = buffer_create(Cursor.Offset)
				buffer_copy(ExactBuf, 0, Cursor.Buffer, 0, Cursor.Offset)
				Remote:FireClient(Player, ExactBuf)
			end
		end

		Cursor.Offset = 0
	end
end

-- Remove a player's cursor on disconnect.
function OutboundBatcher.RemovePlayer(self: any, Player: Player)
	self._Cursors[Player] = nil
end

-- ─── Destroy ─────────────────────────────────────────────────────────────────

function OutboundBatcher.Destroy(self: any)
	if self._Destroyed then return end
	self._Destroyed = true
	table_clear(self._Cursors)
	self._Cursors = nil
	setmetatable(self, nil)
end

-- ─── Module Return ────────────────────────────────────────────────────────────

return table.freeze(setmetatable(OutboundBatcher, {
	__index = function(_, Key)
		Logger:Warn(string_format("OutboundBatcher: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, _Value)
		Logger:Error(string_format("OutboundBatcher: write to protected key '%s'", tostring(Key)))
	end,
}))
