--!strict
--!native
--!optimize 2

--[[
	ResonixNet/Server.lua

	Server-side ResonixNet handle.

	Constructs and wires every server-side module into a single object:
	  Core       — Config, Session, Signal
	  Transport  — Constants, OutboundBatcher
	  Authority  — RateLimiter, OwnershipRegistry
	  Hooks      — ServerHooks (binds all connections, owns Heartbeat flush)

	Public API:
	  handle:Fire(presetKey, position, source?) → emissionId
	    Only valid in ServerAuthority or SharedAuthority mode.

	  handle.OnEmitRejected  — Signal(player, reason)
	  handle.OnEmitAccepted  — Signal(player, presetKey, position, emissionId)

	  handle:Destroy()
]]

local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants         = require(script.Parent.Transport.Constants)
local OutboundBatcher   = require(script.Parent.Transport.OutboundBatcher)
local RateLimiter       = require(script.Parent.Authority.RateLimiter)
local OwnershipRegistry = require(script.Parent.Authority.OwnershipRegistry)
local Config            = require(script.Parent.Core.Config)
local Session           = require(script.Parent.Core.Session)
local Signal            = require(script.Parent.Core.Signal)
local ServerHooks       = require(script.Parent.Hooks.ServerHooks)

local Server = {}

local ServerMethods = {}
local Methods = {__index = ServerMethods}
function ServerMethods.Fire(self,presetKey: string, position: Vector3, source: Instance?): number
	if self._Destroyed then
		warn("ResonixNet.Server:Fire() called on destroyed handle")
		return 0
	end
	if self._Mode ~= "ServerAuthority" and self._Mode ~= "SharedAuthority" then
		error("ResonixNet.Server:Fire() only available in ServerAuthority or SharedAuthority mode", 2)
	end
	return self._HookConnections._FireFromServer(presetKey, position, source)
end

function ServerMethods.Destroy(self)
	if self._Destroyed then return end
	self._Destroyed = true

	for _, Conn in self._HookConnections do
		if typeof(Conn) == "RBXScriptConnection" then
			Conn:Disconnect()
		end
	end
	self._RefillConnection:Disconnect()

	self._Session:Destroy()
	self._OwnershipRegistry:Destroy()
	self._OutboundBatcher:Destroy()

	self.OnEmitRejected:Destroy()
	self.OnEmitAccepted:Destroy()
end

function Server.new(Resonix: any, PresetRegistry_: any, NetworkConfig_: any?): any
	local ResolvedConfig = Config.Resolve(NetworkConfig_)
	local Mode           = (NetworkConfig_ and NetworkConfig_.Mode) or "ClientAuthoritative"

	-- ── Remote setup ─────────────────────────────────────────────────────────
	local Folder = ReplicatedStorage:FindFirstChild(Constants.NETWORK_FOLDER_NAME) :: any
	if not Folder then
		Folder = Instance.new("Folder")
		Folder.Name   = Constants.NETWORK_FOLDER_NAME
		Folder.Parent = ReplicatedStorage
	end

	local Remote = Folder:FindFirstChild(Constants.REMOTE_EMISSION) :: RemoteEvent?
	if not Remote then
		Remote = Instance.new("RemoteEvent")
		Remote.Name   = Constants.REMOTE_EMISSION
		Remote.Parent = Folder
	end

	-- ── Module instances ──────────────────────────────────────────────────────
	local Session_           = Session.new(ResolvedConfig)
	local RateLimiter_       = RateLimiter.new(ResolvedConfig.TokensPerSecond, ResolvedConfig.BurstLimit)
	local OwnershipRegistry_ = OwnershipRegistry.new()
	local OutboundBatcher_   = OutboundBatcher.new()

	-- ── Signals ───────────────────────────────────────────────────────────────
	local OnEmitRejected = Signal.new()
	local OnEmitAccepted = Signal.new()

	-- ── ServerHooks ───────────────────────────────────────────────────────────
	local HookConnections = ServerHooks.Bind({
		Resonix            = Resonix,
		Remote             = Remote,
		Session            = Session_,
		RateLimiter        = RateLimiter_,
		PresetRegistry     = PresetRegistry_,
		OwnershipRegistry  = OwnershipRegistry_,
		OutboundBatcher    = OutboundBatcher_,
		ResolvedConfig     = ResolvedConfig,
		Mode               = Mode,
		OnEmitRejected     = OnEmitRejected,
		OnEmitAccepted     = OnEmitAccepted,
	})

	-- RateLimiter refill runs independently of the OutboundBatcher flush
	-- (which is owned by ServerHooks' Heartbeat connection).
	local RefillConnection = RunService.Heartbeat:Connect(function(DeltaTime: number)
		RateLimiter_:Refill(DeltaTime)
	end)

	-- ── Handle ────────────────────────────────────────────────────────────────
	local self = setmetatable({
		OnEmitRejected     = OnEmitRejected,
		OnEmitAccepted     = OnEmitAccepted,

		_Resonix           = Resonix,
		_Remote            = Remote,
		_Mode              = Mode,
		_Session           = Session_,
		_RateLimiter       = RateLimiter_,
		_OwnershipRegistry = OwnershipRegistry_,
		_OutboundBatcher   = OutboundBatcher_,
		_HookConnections   = HookConnections,
		_RefillConnection  = RefillConnection,
		_Destroyed         = false,
	},Methods)


	return self
end

return Server
