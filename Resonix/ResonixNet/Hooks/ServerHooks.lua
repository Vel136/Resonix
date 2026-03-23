--!native
--!optimize 2
--!strict

--[[
	ResonixNet/Hooks/ServerHooks.lua

	Wires every server-side event into the ResonixNet authority and transport
	pipeline. Never implements business logic — it routes events.

	Connections managed here:
	  Remote.OnServerEvent     → FireValidator → Session.AddEmission →
	                             OwnershipRegistry.Register → Resonix.EmitPreset →
	                             OutboundBatcher.WriteEmitForAll
	  Players.PlayerAdded      → Session.Register → LateJoinHandler.SyncPlayer
	  Players.PlayerRemoving   → cancel owned emissions → Session.Unregister →
	                             RateLimiter.Reset → OutboundBatcher.RemovePlayer
	  RunService.Heartbeat     → OutboundBatcher.Flush

	Server-owned emissions (ServerAuthority / SharedAuthority):
	  Fire() on the handle calls Resonix:EmitPreset() directly, assigns a
	  server emission ID, broadcasts via OutboundBatcher, and registers in
	  OwnershipRegistry with OwnerId = 0 (server-owned).

	SERVER-ONLY. Errors at require() time if loaded on the client.
]]

local Identity    = "ServerHooks"

local ServerHooks = {}
ServerHooks.__type = Identity

-- ─── References ──────────────────────────────────────────────────────────────

local ResonixNet = script.Parent.Parent
local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")

-- ─── Module References ───────────────────────────────────────────────────────

local Authority         = require(ResonixNet.Core.Authority)

Authority.AssertServer("ServerHooks")

local LogService        = require(ResonixNet.Core.Logger)
local FireValidator     = require(ResonixNet.Authority.FireValidator)
local LateJoinHandler   = require(ResonixNet.Reconciliation.LateJoinHandler)
local Serializer        = require(ResonixNet.Transport.Serializer)

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, true)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local string_format = string.format

-- ─── Factory ─────────────────────────────────────────────────────────────────

--[[
	Bind all server-side hooks.

	Ctx fields:
	  Resonix           — live Resonix instance
	  Remote            — single ResonixNet RemoteEvent
	  Session           — Core.Session instance
	  RateLimiter       — Authority.RateLimiter instance
	  PresetRegistry    — Transport.PresetRegistry instance
	  OwnershipRegistry — Authority.OwnershipRegistry instance
	  OutboundBatcher   — Transport.OutboundBatcher instance
	  ResolvedConfig    — Core.Config.Resolve() output
	  Mode              — NetworkMode string
	  OnEmitRejected    — Signal fired on validation failure
	  OnEmitAccepted    — Signal fired when an emission is validated and fired

	Returns a Connections table. Store it and disconnect on Destroy().
]]
function ServerHooks.Bind(Ctx: any): { any }
	local Resonix           = Ctx.Resonix
	local Remote            = Ctx.Remote
	local Session_          = Ctx.Session
	local RateLimiter_      = Ctx.RateLimiter
	local PresetRegistry_   = Ctx.PresetRegistry
	local OwnershipRegistry_= Ctx.OwnershipRegistry
	local OutboundBatcher_  = Ctx.OutboundBatcher
	local ResolvedConfig    = Ctx.ResolvedConfig
	local Mode              = Ctx.Mode
	local OnEmitRejected    = Ctx.OnEmitRejected
	local OnEmitAccepted    = Ctx.OnEmitAccepted

	local ServerCanEmit = (Mode == "ServerAuthority" or Mode == "SharedAuthority")
	local ClientCanEmit = (Mode == "ClientAuthoritative" or Mode == "SharedAuthority")

	local Connections = {}

	-- Monotonically increasing server emission ID counter.
	-- 0 is reserved as "invalid". u32 space wraps after ~2 billion emissions.
	local NextIdCounter = 0
	local function NextEmissionId(): number
		NextIdCounter += 1
		return NextIdCounter
	end

	-- ── Pre-existing players ─────────────────────────────────────────────────
	-- Register any players already in the server when ResonixNet initialises.
	-- Without this, players present before require() have no session entry and
	-- all emit requests from them are silently rejected by Session:CanEmit.
	for _, Player in Players:GetPlayers() do
		Session_:Register(Player)
	end

	-- ── PlayerAdded ──────────────────────────────────────────────────────────
	Connections[#Connections + 1] = Players.PlayerAdded:Connect(function(Player: Player)
		Session_:Register(Player)
		-- Defer by one frame so the Resonix buffer is stable before snapshotting.
		task.defer(function()
			LateJoinHandler.SyncPlayer(
				Player,
				Resonix,
				PresetRegistry_,
				OutboundBatcher_,
				Remote
			)
		end)
	end)

	-- ── PlayerRemoving ────────────────────────────────────────────────────────
	Connections[#Connections + 1] = Players.PlayerRemoving:Connect(function(Player: Player)
		-- Cancel all emissions owned by the leaving player so they stop
		-- attracting AI and are removed from the server buffer immediately.
		-- Without this, a player killed mid-vending-machine interaction would
		-- leave a 60-second emission alive with no owning player to clean it up.
		local OwnedIds = OwnershipRegistry_:GetEmissionsForPlayer(Player)
		local AllPlayers = Players:GetPlayers()
		for _, EmissionId in OwnedIds do
			Resonix:Cancel(tostring(EmissionId))
			OwnershipRegistry_:Unregister(EmissionId)
			Session_:RemoveEmission(Player, EmissionId)

			-- Replicate cancellation to all remaining clients.
			local EncodedCancel = Serializer.EncodeCancel(EmissionId)
			OutboundBatcher_:WriteCancelForAll(AllPlayers, EncodedCancel)
		end

		Session_:Unregister(Player)
		RateLimiter_:Reset(Player)
		OutboundBatcher_:RemovePlayer(Player)
	end)

	-- ── Client fire requests ──────────────────────────────────────────────────
	-- Skipped entirely in ServerAuthority mode — all client requests are dropped.
	Connections[#Connections + 1] = Remote.OnServerEvent:Connect(function(
		Player: Player,
		RawBuf: any
	)
		if not ClientCanEmit then return end

		-- Decode the compact client-fire payload.
		local Ok, Payload = pcall(Serializer.DecodeClientFire, RawBuf)
		if not Ok or not Payload then
			Logger:Warn(string_format(
				"ServerHooks: malformed client fire payload from '%s' (UserId: %d)",
				Player.Name, Player.UserId
			))
			return
		end

		-- Full validation chain: session, origin, preset, rate limit.
		local Result = FireValidator.Validate(
			Player,
			Payload,
			Session_,
			RateLimiter_,
			PresetRegistry_,
			ResolvedConfig
		)

		if not Result.Passed then
			OnEmitRejected:Fire(Player, Result.Reason)
			-- No acknowledgement to the client — see FireValidator for rationale.
			return
		end

		-- Resolve preset key from the hash.
		local PresetKey = PresetRegistry_:KeyOf(Payload.PresetHash)
		-- Already validated by FireValidator but guard defensively.
		if not PresetKey then return end

		-- Assign a server-authoritative emission ID.
		local EmissionId = NextEmissionId()

		-- Emit on the server buffer (authoritative).
		Resonix:EmitPreset(PresetKey, Payload.Position)

		-- Register in authority tables BEFORE replicating to avoid a race
		-- where a cancel arrives between replication and registration.
		Session_:AddEmission(Player, EmissionId)
		OwnershipRegistry_:Register(EmissionId, Player)

		-- Replicate to all clients.
		local ServerTimestamp = workspace:GetServerTimeNow()
		local Preset          = Resonix._presets[PresetKey]
		local EncodedEmit     = Serializer.EncodeEmit(
			EmissionId,
			Payload.PresetHash,
			Payload.Position,
			ServerTimestamp,
			Preset and Preset.Duration or 0
		)

		local AllPlayers = Players:GetPlayers()
		OutboundBatcher_:WriteEmitForAll(AllPlayers, EncodedEmit)

		OnEmitAccepted:Fire(Player, PresetKey, Payload.Position, EmissionId)
	end)

	-- ── Heartbeat: flush outbound batcher ────────────────────────────────────
	-- One FireClient per player per frame regardless of how many emissions
	-- or cancellations occurred in that frame.
	Connections[#Connections + 1] = RunService.Heartbeat:Connect(function()
		OutboundBatcher_:Flush(Remote)
	end)

	-- ── Server-side Fire ─────────────────────────────────────────────────────
	-- Returns a function that lets the server emit directly (ServerAuthority
	-- and SharedAuthority modes). Returns the server emission ID.
	local function FireFromServer(
		PresetKey : string,
		Position  : Vector3,
		Source    : Instance?
	): number
		if not ServerCanEmit then
			Logger:Error("ServerHooks.FireFromServer: Mode is ClientAuthoritative — server cannot emit")
			return 0
		end

		local PresetHash = PresetRegistry_:HashOf(PresetKey)
		if not PresetHash then
			Logger:Warn(string_format(
				"ServerHooks.FireFromServer: unknown preset '%s'",
				PresetKey
			))
			return 0
		end

		local EmissionId = NextEmissionId()

		Resonix:EmitPreset(PresetKey, Position, Source)

		-- Server-owned: OwnerId = 0, not tracked in OwnershipRegistry.
		-- Server emissions don't need player-level ownership tracking since
		-- there's no session budget to enforce or cancel-on-leave logic.

		local ServerTimestamp = workspace:GetServerTimeNow()
		local Preset          = Resonix._presets[PresetKey]
		local EncodedEmit     = Serializer.EncodeEmit(
			EmissionId,
			PresetHash,
			Position,
			ServerTimestamp,
			Preset and Preset.Duration or 0
		)

		local AllPlayers = Players:GetPlayers()
		OutboundBatcher_:WriteEmitForAll(AllPlayers, EncodedEmit)

		return EmissionId
	end

	-- Exposed on the Connections table so Server.lua can call it.
	Connections._FireFromServer = FireFromServer

	return Connections
end

-- ─── Module Return ────────────────────────────────────────────────────────────

return table.freeze(setmetatable(ServerHooks, {
	__index = function(_, Key)
		Logger:Warn(string_format("ServerHooks: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, _Value)
		Logger:Error(string_format("ServerHooks: write to protected key '%s'", tostring(Key)))
	end,
}))
