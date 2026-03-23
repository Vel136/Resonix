--!strict

--[[
	ResonixNet Type Definitions
	
	All network-specific types for ResonixNet.
]]

export type NetworkMode = "ClientAuthoritative" | "ServerAuthority" | "SharedAuthority"

export type NetworkConfig = {
	-- Authority mode
	Mode: NetworkMode?,

	-- Rate limiting
	TokensPerSecond: number?,
	BurstLimit: number?,

	-- Validation
	MaxOriginTolerance: number?,

	-- Replication
	ReplicateState: boolean?,
}

export type EmissionPayload = {
	PresetKey: string,
	Position: Vector3,
	PresetHash: number?,
}

export type PresetRegistry = typeof(setmetatable({} :: {
	_presets: { [string]: number },
	_reverseMap: { [number]: string },
	_nextHash: number,
}, { __index = {} }))

return {}
