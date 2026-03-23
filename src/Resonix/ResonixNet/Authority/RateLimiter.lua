--!strict

--[[
	RateLimiter
	
	Token bucket rate limiter for sound emissions.
	Prevents clients from spamming sounds to the server.
]]

local RateLimiter = {}
RateLimiter.__index = RateLimiter
RateLimiter.__type = "RateLimiter"

export type RateLimiter = typeof(setmetatable({} :: {
	_tokens: { [any]: number },
	_tokensPerSecond: number,
	_burstLimit: number,
}, { __index = RateLimiter }))

--[[
	Creates a new RateLimiter.
	
	@param tokensPerSecond number
	@param burstLimit number
	@return RateLimiter
]]
function RateLimiter.new(tokensPerSecond: number, burstLimit: number): RateLimiter
	local self = setmetatable({} :: any, { __index = RateLimiter })
	self._tokens = {}
	self._tokensPerSecond = tokensPerSecond
	self._burstLimit = burstLimit
	return self
end

--[[
	Refills tokens for all tracked identities.
	Call this once per frame with the delta time.
	
	@param deltaTime number
]]
function RateLimiter.Refill(self: RateLimiter, deltaTime: number)
	for key in self._tokens do
		self._tokens[key] = math.min(
			self._tokens[key] + (self._tokensPerSecond * deltaTime),
			self._burstLimit
		)
	end
end

--[[
	Attempts to consume one token for the given identity.
	
	@param identity any (typically a Player)
	@return boolean True if token was available and consumed, false otherwise
]]
function RateLimiter.TryConsume(self: RateLimiter, identity: any): boolean
	local tokens = self._tokens[identity] or self._burstLimit

	if tokens >= 1 then
		self._tokens[identity] = tokens - 1
		return true
	end

	return false
end

--[[
	Reset tokens for an identity (e.g., on disconnect).
	
	@param identity any
]]
function RateLimiter.Reset(self: RateLimiter, identity: any)
	self._tokens[identity] = nil
end

return RateLimiter
