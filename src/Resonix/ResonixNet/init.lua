--!strict
--!native
--!optimize 2

--[[
	ResonixNet

	Full-stack network middleware for Resonix.
	Environment-aware: returns a server handle on the server, client handle
	on the client. Both share the same PresetRegistry.

	Usage:
	    -- Both server and client:
	    local Net = ResonixNet.new(resonix, presetRegistry, {
	        Mode              = "ClientAuthoritative",  -- default
	        TokensPerSecond   = 20,
	        BurstLimit        = 40,
	        MaxOriginTolerance = 15,
	        LatencyBuffer     = 0,     -- 0 = auto half-RTT
	        ReplicateState    = true,
	    })

	    -- Server only:
	    Net:Fire("Gunshot_Rifle", muzzlePosition)

	    -- Client only:
	    Net:Fire("Footstep_Walk", characterPosition)

	NetworkMode values:
	    "ClientAuthoritative" — clients send fire requests; server validates
	                            and replicates. Default.
	    "ServerAuthority"     — only server can emit via handle:Fire().
	                            Client :Fire() is a no-op.
	    "SharedAuthority"     — both server handle:Fire() and client :Fire()
	                            are permitted.
]]

local RunService = game:GetService("RunService")

local Server         = require(script.Server)
local Client         = require(script.Client)
local PresetRegistry = require(script.Transport.PresetRegistry)

local ResonixNet = {}
ResonixNet.PresetRegistry = PresetRegistry

function ResonixNet.new(Resonix: any, PresetRegistry_: any, NetworkConfig_: any?): any
	if RunService:IsServer() then
		return Server.new(Resonix, PresetRegistry_, NetworkConfig_)
	else
		return Client.new(Resonix, PresetRegistry_, NetworkConfig_)
	end
end

return ResonixNet
