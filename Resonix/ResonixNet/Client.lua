--!strict
--!native
--!optimize 2

--[[
	ResonixNet/Client.lua

	Client-side ResonixNet handle.

	Constructs and wires every client-side module into a single object:
	  Core           — Config, Signal
	  Transport      — Constants
	  Reconciliation — CosmeticTracker, DriftCorrector, LatencyBuffer
	  Hooks          — ClientHooks (single OnClientEvent decoder loop)

	Public API:
	  handle:Fire(presetKey, position)
	    Send an emission request to the server. Encodes as a compact
	    binary payload via Serializer rather than sending raw strings.
	    No-op in ServerAuthority mode — the server owns all emissions.

	  handle.OnEmitReceived   — Signal(serverEmissionId, presetKey, position)
	  handle.OnCancelReceived — Signal(serverEmissionId)

	  handle:Destroy()
]]
-- ── Services ───────────────────────────────────────────────────────────
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── References ───────────────────────────────────────────────────────────
local ResonixNet	 = script.Parent
local Core			 = ResonixNet.Core
local Constants      = require(ResonixNet.Transport.Constants)
local PresetRegistry = require(ResonixNet.Transport.PresetRegistry)
local Serializer     = require(ResonixNet.Transport.Serializer)
local Config         = require(ResonixNet.Core.Config)
local Signal         = require(ResonixNet.Core.Signal)
local ClientHooks    = require(ResonixNet.Hooks.ClientHooks)

local Client = {}

local ClientMethods = {}
local Methods = {__index = ClientMethods}

--[[
		Send an emission request to the server.

		The payload is a compact binary buffer (14 bytes: u16 hash + f32x3
		position) rather than the raw string+Vector3 the old implementation
		sent. This matches what ServerHooks.OnServerEvent expects to decode.

		presetKey  — must be registered in PresetRegistry on both sides
		position   — world-space origin of the sound
	]]
function ClientMethods.Fire(self,presetKey: string, position: Vector3)
	if self._Destroyed then return end

	local PresetHash = self._PresetRegistry:HashOf(presetKey)
	if not PresetHash then
		warn(string.format("ResonixNet.Client:Fire() — unknown preset '%s'", presetKey))
		return
	end

	local EncodedPayload = Serializer.EncodeClientFire(PresetHash, position)
	self._Remote:FireServer(EncodedPayload)
end

function ClientMethods.Destroy(self)
	if self._Destroyed then return end
	self._Destroyed = true

	for _, Conn in self._HookConnections do
		if typeof(Conn) == "RBXScriptConnection" then
			Conn:Disconnect()
		end
	end

	-- Destroy reconciliation objects stored on the connections table.
	if self._HookConnections._Tracker then
		self._HookConnections._Tracker:Destroy()
	end
	if self._HookConnections._Corrector then
		self._HookConnections._Corrector:Destroy()
	end

	self.OnEmitReceived:Destroy()
	self.OnCancelReceived:Destroy()
end

function Client.new(Resonix: any, PresetRegistry_: any, NetworkConfig_: any?): any
	local ResolvedConfig = Config.Resolve(NetworkConfig_)

	-- Wait for the remote the server creates.
	local Folder = ReplicatedStorage:WaitForChild(Constants.NETWORK_FOLDER_NAME) :: Folder
	local Remote = Folder:WaitForChild(Constants.REMOTE_EMISSION) :: RemoteEvent

	-- ── Signals ───────────────────────────────────────────────────────────────
	local OnEmitReceived   = Signal.new()
	local OnCancelReceived = Signal.new()

	-- ── ClientHooks ───────────────────────────────────────────────────────────
	local HookConnections = ClientHooks.Bind(
		Resonix,
		PresetRegistry_,
		Remote,
		ResolvedConfig,
		OnEmitReceived,
		OnCancelReceived
	)

	-- ── Handle ────────────────────────────────────────────────────────────────
	local self = setmetatable( {
		OnEmitReceived     = OnEmitReceived,
		OnCancelReceived   = OnCancelReceived,

		_Resonix           = Resonix,
		_Remote            = Remote,
		_PresetRegistry    = PresetRegistry_,
		_ResolvedConfig    = ResolvedConfig,
		_HookConnections   = HookConnections,
		_Destroyed         = false,
	}, Methods)



	return self
end

return Client
