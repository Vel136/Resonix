--!native
--!optimize 2
--!strict

--[[
	ResonixNet/Core/Config.lua

	Resolves the consumer-supplied NetworkConfig against Constants defaults.

	All validation runs at construction time. After Resolve() the returned
	table is frozen — no module may mutate it after construction.

	Config fields:
	  MaxOriginTolerance   — how far a client's emission origin may be from
	                         their character (studs). Prevents position spoofing.
	  MaxConcurrentEmits   — cap on how many emissions a single player can have
	                         active simultaneously.
	  TokensPerSecond      — sustained emission rate cap (token bucket).
	  BurstLimit           — burst cap (allows rapid back-to-back events).
	  LatencyBuffer        — fixed client-side delay (seconds) applied when
	                         reconstructing emissions. 0 = auto (half-RTT).
	  ClockSyncRate        — how aggressively the client corrects its emission
	                         expiry timestamps toward the server clock.
	  ReplicateState       — whether the server sends full state batches for
	                         late-join sync (default true).
]]

local Identity = "Config"

local Config   = {}
Config.__type  = Identity

-- ─── References ──────────────────────────────────────────────────────────────

local Transport = script.Parent.Parent.Transport

-- ─── Module References ───────────────────────────────────────────────────────

local Constants  = require(Transport.Constants)
local LogService = require(script.Parent.Logger)

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, true)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local table_freeze  = table.freeze
local string_format = string.format

-- ─── Types ───────────────────────────────────────────────────────────────────

export type ResolvedConfig = {
	MaxOriginTolerance   : number,
	MaxConcurrentEmits   : number,
	TokensPerSecond      : number,
	BurstLimit           : number,
	LatencyBuffer        : number,
	ClockSyncRate        : number,
	ReplicateState       : boolean,
}

-- ─── Factory ─────────────────────────────────────────────────────────────────

function Config.Resolve(RawConfig: any?): ResolvedConfig
	local Raw = RawConfig or {}

	local function ValidateNumber(Field: string, Value: any): boolean
		if Value ~= nil and type(Value) ~= "number" then
			Logger:Warn(string_format(
				"Config.Resolve: field '%s' must be a number, got %s — using default",
				Field, typeof(Value)
			))
			return false
		end
		return true
	end

	local MaxOriginTolerance = ValidateNumber("MaxOriginTolerance", Raw.MaxOriginTolerance) and Raw.MaxOriginTolerance or Constants.DEFAULT_MAX_ORIGIN_TOLERANCE
	local MaxConcurrentEmits = ValidateNumber("MaxConcurrentEmits", Raw.MaxConcurrentEmits) and Raw.MaxConcurrentEmits or Constants.DEFAULT_MAX_CONCURRENT_EMITS
	local TokensPerSecond    = ValidateNumber("TokensPerSecond",    Raw.TokensPerSecond)    and Raw.TokensPerSecond    or Constants.DEFAULT_TOKENS_PER_SECOND
	local BurstLimit         = ValidateNumber("BurstLimit",         Raw.BurstLimit)         and Raw.BurstLimit         or Constants.DEFAULT_BURST_LIMIT
	local LatencyBuffer      = ValidateNumber("LatencyBuffer",      Raw.LatencyBuffer)      and Raw.LatencyBuffer      or 0
	local ClockSyncRate      = ValidateNumber("ClockSyncRate",      Raw.ClockSyncRate)      and Raw.ClockSyncRate      or Constants.DEFAULT_CLOCK_SYNC_RATE

	local ReplicateState = true
	if Raw.ReplicateState ~= nil then
		if type(Raw.ReplicateState) ~= "boolean" then
			Logger:Warn("Config.Resolve: field 'ReplicateState' must be a boolean — using default (true)")
		else
			ReplicateState = Raw.ReplicateState
		end
	end

	-- Range checks
	if MaxOriginTolerance <= 0 then
		Logger:Warn("Config: MaxOriginTolerance must be > 0 — clamping to default")
		MaxOriginTolerance = Constants.DEFAULT_MAX_ORIGIN_TOLERANCE
	end
	if MaxConcurrentEmits < 1 then
		Logger:Warn("Config: MaxConcurrentEmits must be >= 1 — clamping to default")
		MaxConcurrentEmits = Constants.DEFAULT_MAX_CONCURRENT_EMITS
	end
	if TokensPerSecond <= 0 then
		Logger:Warn("Config: TokensPerSecond must be > 0 — clamping to default")
		TokensPerSecond = Constants.DEFAULT_TOKENS_PER_SECOND
	end
	if BurstLimit < TokensPerSecond then
		Logger:Warn("Config: BurstLimit should be >= TokensPerSecond — clamping")
		BurstLimit = TokensPerSecond
	end
	if ClockSyncRate <= 0 then
		Logger:Warn("Config: ClockSyncRate must be > 0 — clamping to default")
		ClockSyncRate = Constants.DEFAULT_CLOCK_SYNC_RATE
	end
	if LatencyBuffer < 0 then
		Logger:Warn("Config: LatencyBuffer must be >= 0 — clamping to 0")
		LatencyBuffer = 0
	end

	return table_freeze({
		MaxOriginTolerance   = MaxOriginTolerance,
		MaxConcurrentEmits   = MaxConcurrentEmits,
		TokensPerSecond      = TokensPerSecond,
		BurstLimit           = BurstLimit,
		LatencyBuffer        = LatencyBuffer,
		ClockSyncRate        = ClockSyncRate,
		ReplicateState       = ReplicateState,
	})
end

-- ─── Module Return ────────────────────────────────────────────────────────────

return table.freeze(setmetatable(Config, {
	__index = function(_, Key)
		Logger:Warn(string_format("Config: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, _Value)
		Logger:Error(string_format("Config: write to protected key '%s'", tostring(Key)))
	end,
}))
