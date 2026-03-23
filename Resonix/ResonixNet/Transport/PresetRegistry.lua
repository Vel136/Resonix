--!strict

--[[
	PresetRegistry
	
	Manages sound preset identification and hashing for network transmission.
	Similar to VetraNet's BehaviorRegistry.
	
	Both server and client must register presets in the same order.
	Fire payloads carry only a u16 hash — if hashes diverge,
	every fire request will be rejected.
]]

local PresetRegistry = {}
PresetRegistry.__index = PresetRegistry
PresetRegistry.__type = "PresetRegistry"

export type PresetRegistry = typeof(setmetatable({} :: {
	_presets: { [string]: number },
	_reverseMap: { [number]: string },
	_nextHash: number,
}, { __index = PresetRegistry }))

--[[
	Creates a new PresetRegistry.
	
	@return PresetRegistry
]]
function PresetRegistry.new(): PresetRegistry
	local self = setmetatable({} :: any, { __index = PresetRegistry })
	self._presets = {}
	self._reverseMap = {}
	self._nextHash = 0
	return self
end

--[[
	Registers a preset with the given key.
	
	Must be called in the same order on both server and client.
	Returns a numeric hash used for network transmission.
	
	@param key string
	@return number The preset hash
]]
function PresetRegistry.Register(self: PresetRegistry, key: string): number
	if self._presets[key] then
		return self._presets[key]
	end

	local hash = self._nextHash
	self._presets[key] = hash
	self._reverseMap[hash] = key
	self._nextHash += 1

	return hash
end

--[[
	Gets the hash for a preset key.
	
	@param key string
	@return number? The hash, or nil if not registered
]]
function PresetRegistry.HashOf(self: PresetRegistry, key: string): number?
	return self._presets[key]
end

--[[
	Gets the preset key for a hash.
	
	@param hash number
	@return string? The key, or nil if hash not found
]]
function PresetRegistry.KeyOf(self: PresetRegistry, hash: number): string?
	return self._reverseMap[hash]
end

--[[
	Checks if a preset is registered.
	
	@param key string
	@return boolean
]]
function PresetRegistry.IsRegistered(self: PresetRegistry, key: string): boolean
	return self._presets[key] ~= nil
end

return PresetRegistry
