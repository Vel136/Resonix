--!native
--!optimize 2
--!strict

--[[
	ResonixNet/Transport/Serializer.lua

	Low-level buffer primitive layer for emission payloads.

	Knows how to read and write raw types into a Roblox buffer.
	Has no knowledge of what a preset or emission is — only knows types:
	Vector3, f32, f64, u8, u16, u32, boolean, timestamp.

	Every function follows the pattern:
	    Write*(buf, offset, value) → nextOffset
	    Read*(buf, offset)        → (value, nextOffset)

	Payload sizes:
	    EMIT payload   = u32(4) + u16(2) + Vector3/f32x3(12) + f64(8) + f32(4) = 30 bytes
	    CANCEL payload = u32(4)                                                   = 4  bytes
	    STATE entry    = u32(4) + u16(2) + Vector3/f32x3(12) + f64(8) + f64(8)  = 34 bytes
	    STATE header   = u16(2) + u32(4)                                          = 6  bytes
]]

local Identity   = "Serializer"

local Serializer = {}
Serializer.__type = Identity

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local buffer_writef32 = buffer.writef32
local buffer_writef64 = buffer.writef64
local buffer_writeu8  = buffer.writeu8
local buffer_writeu16 = buffer.writeu16
local buffer_writeu32 = buffer.writeu32
local buffer_readf32  = buffer.readf32
local buffer_readf64  = buffer.readf64
local buffer_readu8   = buffer.readu8
local buffer_readu16  = buffer.readu16
local buffer_readu32  = buffer.readu32

local string_format   = string.format

-- ─── Primitive Writers ────────────────────────────────────────────────────────

-- f32 — single-precision float for positions. f32 gives ~7 significant
-- decimal digits, sufficient for stud-level precision at map scale.
function Serializer.WriteF32(Buffer: buffer, Offset: number, Value: number): number
	buffer_writef32(Buffer, Offset, Value)
	return Offset + 4
end

function Serializer.ReadF32(Buffer: buffer, Offset: number): (number, number)
	return buffer_readf32(Buffer, Offset), Offset + 4
end

-- f64 — double-precision float for timestamps. Sub-millisecond precision
-- is needed to correctly compute ExpiresAt on the client from the server clock.
function Serializer.WriteF64(Buffer: buffer, Offset: number, Value: number): number
	buffer_writef64(Buffer, Offset, Value)
	return Offset + 8
end

function Serializer.ReadF64(Buffer: buffer, Offset: number): (number, number)
	return buffer_readf64(Buffer, Offset), Offset + 8
end

-- u8 — 8-bit unsigned integer [0, 255].
function Serializer.WriteU8(Buffer: buffer, Offset: number, Value: number): number
	buffer_writeu8(Buffer, Offset, Value)
	return Offset + 1
end

function Serializer.ReadU8(Buffer: buffer, Offset: number): (number, number)
	return buffer_readu8(Buffer, Offset), Offset + 1
end

-- u16 — 16-bit unsigned integer [0, 65535]. Used for preset hashes and
-- emission counts. 65535 unique presets far exceeds any realistic game.
function Serializer.WriteU16(Buffer: buffer, Offset: number, Value: number): number
	buffer_writeu16(Buffer, Offset, Value)
	return Offset + 2
end

function Serializer.ReadU16(Buffer: buffer, Offset: number): (number, number)
	return buffer_readu16(Buffer, Offset), Offset + 2
end

-- u32 — 32-bit unsigned integer [0, 4294967295]. Used for server emission IDs.
-- At 20 emissions/second the counter wraps after ~2.5 years of continuous use.
function Serializer.WriteU32(Buffer: buffer, Offset: number, Value: number): number
	buffer_writeu32(Buffer, Offset, Value)
	return Offset + 4
end

function Serializer.ReadU32(Buffer: buffer, Offset: number): (number, number)
	return buffer_readu32(Buffer, Offset), Offset + 4
end

-- Vector3 — three consecutive f32 values (X, Y, Z). 12 bytes total.
function Serializer.WriteVector3(Buffer: buffer, Offset: number, Value: Vector3): number
	buffer_writef32(Buffer, Offset,     Value.X)
	buffer_writef32(Buffer, Offset + 4, Value.Y)
	buffer_writef32(Buffer, Offset + 8, Value.Z)
	return Offset + 12
end

function Serializer.ReadVector3(Buffer: buffer, Offset: number): (Vector3, number)
	local X = buffer_readf32(Buffer, Offset)
	local Y = buffer_readf32(Buffer, Offset + 4)
	local Z = buffer_readf32(Buffer, Offset + 8)
	return Vector3.new(X, Y, Z), Offset + 12
end

-- Timestamp — f64. workspace:GetServerTimeNow() returns a double-precision
-- value. f32 would lose ~10-100ms of precision, enough to corrupt expiry
-- timing. All timestamps on the wire are in server-clock space.
function Serializer.WriteTimestamp(Buffer: buffer, Offset: number, Value: number): number
	buffer_writef64(Buffer, Offset, Value)
	return Offset + 8
end

function Serializer.ReadTimestamp(Buffer: buffer, Offset: number): (number, number)
	return buffer_readf64(Buffer, Offset), Offset + 8
end

-- ─── Payload Encoders / Decoders ──────────────────────────────────────────────

-- EMIT payload (30 bytes):
--   ServerEmissionId (u32) | PresetHash (u16) | Position (f32x3) |
--   ServerTimestamp (f64)  | Duration (f32)
--
-- ServerTimestamp is workspace:GetServerTimeNow() at the moment of emission.
-- The client uses this alongside its own GetServerTimeNow() to compute the
-- remaining lifetime in local os.clock() space — see ClockDriftCorrector.
function Serializer.EncodeEmit(
	ServerEmissionId : number,
	PresetHash       : number,
	Position         : Vector3,
	ServerTimestamp  : number,
	Duration         : number
): buffer
	local Buf = buffer.create(30)
	local Off = 0
	Off = Serializer.WriteU32(Buf, Off, ServerEmissionId)
	Off = Serializer.WriteU16(Buf, Off, PresetHash)
	Off = Serializer.WriteVector3(Buf, Off, Position)
	Off = Serializer.WriteTimestamp(Buf, Off, ServerTimestamp)
	Off = Serializer.WriteF32(Buf, Off, Duration)
	return Buf
end

function Serializer.DecodeEmit(Buf: buffer): {
	ServerEmissionId : number,
	PresetHash       : number,
	Position         : Vector3,
	ServerTimestamp  : number,
	Duration         : number,
}
	local Off = 0
	local ServerEmissionId: number
	local PresetHash: number
	local Position: Vector3
	local ServerTimestamp: number
	local Duration: number
	ServerEmissionId, Off = Serializer.ReadU32(Buf, Off)
	PresetHash,       Off = Serializer.ReadU16(Buf, Off)
	Position,         Off = Serializer.ReadVector3(Buf, Off)
	ServerTimestamp,  Off = Serializer.ReadTimestamp(Buf, Off)
	Duration,         Off = Serializer.ReadF32(Buf, Off)
	return {
		ServerEmissionId = ServerEmissionId,
		PresetHash       = PresetHash,
		Position         = Position,
		ServerTimestamp  = ServerTimestamp,
		Duration         = Duration,
	}
end

-- CANCEL payload (4 bytes): ServerEmissionId (u32)
function Serializer.EncodeCancel(ServerEmissionId: number): buffer
	local Buf = buffer.create(4)
	Serializer.WriteU32(Buf, 0, ServerEmissionId)
	return Buf
end

function Serializer.DecodeCancel(Buf: buffer): number
	return Serializer.ReadU32(Buf, 0)
end

-- CLIENT FIRE payload (14 bytes): PresetHash (u16) | Position (f32x3)
-- Sent client→server via FireServer. Not batched — each fire is one call.
function Serializer.EncodeClientFire(
	PresetHash : number,
	Position   : Vector3
): buffer
	local Buf = buffer.create(14)
	local Off = 0
	Off = Serializer.WriteU16(Buf, Off, PresetHash)
	Off = Serializer.WriteVector3(Buf, Off, Position)
	return Buf
end

function Serializer.DecodeClientFire(Buf: buffer): {
	PresetHash : number,
	Position   : Vector3,
}
	local Off = 0
	local PresetHash: number
	local Position: Vector3
	PresetHash, Off = Serializer.ReadU16(Buf, Off)
	Position,   Off = Serializer.ReadVector3(Buf, Off)
	return {
		PresetHash = PresetHash,
		Position   = Position,
	}
end

-- STATE BATCH (late-join sync):
--   Count (u16) | FrameId (u32)
--   Per entry: ServerEmissionId (u32) | PresetHash (u16) |
--              Position (f32x3) | ServerEmittedAt (f64) | ServerExpiresAt (f64)
--   = 6 + Count * 34 bytes
function Serializer.EncodeStateBatch(
	FrameId : number,
	Entries : { any },
	Count   : number
): buffer
	local BufSize = 6 + Count * 34
	local Buf = buffer.create(BufSize)
	local Off = 0
	Off = Serializer.WriteU16(Buf, Off, Count)
	Off = Serializer.WriteU32(Buf, Off, FrameId)
	for i = 1, Count do
		local E = Entries[i]
		Off = Serializer.WriteU32(Buf, Off, E.ServerEmissionId)
		Off = Serializer.WriteU16(Buf, Off, E.PresetHash)
		Off = Serializer.WriteVector3(Buf, Off, E.Position)
		Off = Serializer.WriteTimestamp(Buf, Off, E.ServerEmittedAt)
		Off = Serializer.WriteTimestamp(Buf, Off, E.ServerExpiresAt)
	end
	return Buf
end

function Serializer.DecodeStateBatch(Buf: buffer): {
	Count   : number,
	FrameId : number,
	Entries : { any },
}
	local Off = 0
	local Count: number
	local FrameId: number
	Count,   Off = Serializer.ReadU16(Buf, Off)
	FrameId, Off = Serializer.ReadU32(Buf, Off)
	local Entries = table.create(Count)
	for i = 1, Count do
		local ServerEmissionId: number
		local PresetHash: number
		local Position: Vector3
		local ServerEmittedAt: number
		local ServerExpiresAt: number
		ServerEmissionId, Off = Serializer.ReadU32(Buf, Off)
		PresetHash,       Off = Serializer.ReadU16(Buf, Off)
		Position,         Off = Serializer.ReadVector3(Buf, Off)
		ServerEmittedAt,  Off = Serializer.ReadTimestamp(Buf, Off)
		ServerExpiresAt,  Off = Serializer.ReadTimestamp(Buf, Off)
		Entries[i] = {
			ServerEmissionId = ServerEmissionId,
			PresetHash       = PresetHash,
			Position         = Position,
			ServerEmittedAt  = ServerEmittedAt,
			ServerExpiresAt  = ServerExpiresAt,
		}
	end
	return { Count = Count, FrameId = FrameId, Entries = Entries }
end

-- ─── Module Return ────────────────────────────────────────────────────────────

return table.freeze(setmetatable(Serializer, {
	__index = function(_, Key)
		error(string_format("[ResonixNet.Serializer] Nil key '%s'", tostring(Key)), 2)
	end,
	__newindex = function(_, Key, _Value)
		error(string_format("[ResonixNet.Serializer] Write to protected key '%s'", tostring(Key)), 2)
	end,
}))
