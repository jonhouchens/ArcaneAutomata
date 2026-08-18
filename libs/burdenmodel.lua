--[[
burdenmodel.lua (v2.5) — standalone PUP burden/overload library for Ashita v4
Install: Ashita/addons/libs/burdenmodel.lua
Usage from any addon:

    local burden = require('burdenmodel')
    local stats = require('pupstats').attach({ alias = 'myaddon_pupstats' })

    -- Option A: self-wiring (registers its own packet_in/d3d_present handlers)
    local model = burden.attach({
        thresh_gear = 5,          -- Horizon: 0, or 5 IF Puppetry Dastanas'
                                  -- effect is implemented as LSB's +5 (unverified)
        heatsink    = true,
        frame_half_dark = false,  -- true on Valoredge / Sharpshot
        stat_diff = function(element, phase)
            return stats:stat_diff(element, phase)
        end,
    })
    -- model:chance(burden.ELEMENT.FIRE) -> % or nil (unknown)
    -- model:get(e) -> gauge|nil, quality ('exact'|'estimate'|'bound'|'unknown')
    -- Optional diagnostics: model:set_telemetry_sink(function(event) ... end)
    -- Serialize with burden.telemetry_csv_header()/telemetry_csv_row(event).
    -- On addon unload: model:detach(); stats:detach()

    -- Option B: pure model, you feed events (runs headless for tests)
    local model = burden.new({ thresh_gear = 5 })
    model:on_activate(); model:on_maneuver(burden.ELEMENT.FIRE); ...

--------------------------------------------------------------------------
GROUND TRUTH — LandSandBoat/server, base branch, pulled 2026-08-14
  src/map/entities/automaton_entity.cpp    burdenTick / addBurden / overloadChance
  scripts/globals/automaton.lua            getAddBurdenValue / onUseManeuver / heatsink
  scripts/globals/pets/automaton.lua       spawn seeding (+35 all elements)
  src/map/utils/petutils.cpp:1817          new CAutomatonEntity per Activate
  src/map/packets/s2c/0x028_battle2.cpp    0x28 wire layout (authoritative widths)
  sql/abilities.sql                        Activate=136 Deactivate=139 Maneuvers=141..148
  data/status_effects.yaml                 Overload=299, Fire..Dark Maneuver=300..307
  msg enums                                798 = overload chance %, 799 = overloaded

CAVEAT: current LSB is definitive for current LSB. Horizon is a private fork.
The packet layout still matches, but telemetry captured on Horizon on
2026-08-14 demonstrated different spawn, Dark-gain, and Heatsink behavior.
Treat 798/799 as the authority.

HORIZON MODEL (observed unless explicitly marked as an LSB prior)
  * 8 gauges (uint8 0..255), element index 0..7:
      0=Fire 1=Ice 2=Wind 3=Earth 4=Thunder 5=Water 6=Light 7=Dark
  * Activate: fresh entity; every gauge = 30. Nothing persists past Deactivate.
  * Decay each 3s server-global status tick: 1 burden normally.
      Heatsink: total decay 1/2/3/4 by active WATER maneuvers (0..3).
      Zero through two Water Maneuvers were measured directly; three is the
      linear extrapolation. Heatsink affects every elemental gauge.
      Decay continues while overloaded.
  * Maneuver gain:
      Dark: 15 on normal frames (observed); 8 on Valoredge/Sharpshot (LSB prior)
      Else, d = masterStat - petStat: d>=4 -> 14; 0<=d<4 -> 19-d; d<0 -> 20
  * Threshold = 30 + OVERLOAD_THRESH on the master.
      Horizon-era sources: none confirmed. LSB grants +5 on Puppetry Dastanas
      (and +5 on Buffoon's Collar, which Horizon does not have).
  * On maneuver, post-gain: if gauge > thresh, roll(0..99) < gauge-thresh+5
      -> OVERLOAD for (gauge - thresh) seconds; strips all maneuvers.
      Overload (buff 299) lives on the MASTER: it blocks maneuvers, survives
      pet despawn, and is NOT removed by Deactivate.
  * Every maneuver's action packet carries message 798/799 with
      param = clamp(gauge - thresh + 5, 0, 255)  (post-gain).
    param > 0 back-solves that element's gauge EXACTLY:
      gauge = param + thresh - 5.
    param == 0 only bounds it: gauge <= thresh - 5.

UNSUPPORTED / OUT OF SCOPE
  * SUPPRESS_OVERLOAD (Kenkonken, the level-75 Mythic): not modeled. If it
    ever becomes obtainable, set cfg.gain_divisor = 3 to approximate LSB's
    integer-divide-by-3 on incoming burden.
  * PREVENT_OVERLOAD: dead code in LSB base (no grant source); ignored.
  * Master-side BURDEN_DECAY gear: none at 75; cfg.extra_decay covers it.
]]

local lib = {}
lib.VERSION = '2.5'

--------------------------------------------------------------------------
-- constants (exported for other addons)
--------------------------------------------------------------------------
lib.ELEMENT = {
    FIRE = 0, ICE = 1, WIND = 2, EARTH = 3,
    THUNDER = 4, WATER = 5, LIGHT = 6, DARK = 7,
}

lib.ELEMENT_NAME = {
    [0] = 'Fire', [1] = 'Ice', [2] = 'Wind', [3] = 'Earth',
    [4] = 'Thunder', [5] = 'Water', [6] = 'Light', [7] = 'Dark',
}

lib.ABILITY = {
    ACTIVATE       = 136,
    DEACTIVATE     = 139,
    MANEUVER_FIRST = 141,   -- Fire Maneuver
    MANEUVER_LAST  = 148,   -- Dark Maneuver (element = id - 141)
}

lib.BUFF = {
    OVERLOAD       = 299,
    MANEUVER_FIRST = 300,   -- Fire Maneuver
    MANEUVER_LAST  = 307,   -- Dark Maneuver
}

lib.MSG = {
    OVERLOAD_CHANCE = 798,  -- "The <pet>'s overload chance is N%."
    OVERLOADED      = 799,  -- same + "The <pet> is overloaded!"
}

-- Gauge knowledge quality, worst -> best.
--   unknown  : no information (cold attach)
--   bound    : upper bound only (798 param 0 => gauge <= thresh-5)
--   estimate : projected value (modeled gains and/or locally-phased decay)
--   exact    : server-anchored (Activate seed or positive 798/799 param)
--              and no modeled decay applied since; downgrades to estimate
--              on the first tick that subtracts from it (0 stays exact)
lib.QUALITY = { UNKNOWN = 'unknown', BOUND = 'bound', ESTIMATE = 'estimate', EXACT = 'exact' }

-- Stable CSV schema for optional diagnostic sinks. Consumers may add wall_time
-- before serialization; every other field is populated by the model when it is
-- relevant to the event.
lib.TELEMETRY_COLUMNS = {
    'wall_time', 'clock', 'event', 'model_version', 'element', 'action_id', 'message', 'param',
    'predicted_param', 'predicted_risk', 'residual', 'gauge_residual',
    'gauge_before', 'quality_before',
    'gauge_predicted', 'quality_predicted', 'gauge_after', 'quality_after',
    'threshold', 'estimated_gain', 'decay_per_tick', 'decay_steps',
    'fire_maneuvers', 'maneuver_buffs', 'gauges', 'qualities', 'active',
    'overload_observed', 'frame_half_dark', 'heatsink', 'thresh_gear',
    'gain_divisor', 'extra_decay', 'last_tick', 'tick_phase', 'note',
    'stat_name', 'master_stat', 'master_stat_base', 'master_stat_modifier',
    'pet_stat', 'pet_stat_base', 'pet_stat_additional', 'stat_diff',
    'stat_source', 'pet_stat_age',
}

local function csv_escape(value)
    if value == nil then return '' end
    local text = tostring(value)
    if text:find('[,"\r\n]') then
        return '"' .. text:gsub('"', '""') .. '"'
    end
    return text
end

function lib.telemetry_csv_header()
    return table.concat(lib.TELEMETRY_COLUMNS, ',')
end

function lib.telemetry_csv_row(event)
    local values = {}
    for index, key in ipairs(lib.TELEMETRY_COLUMNS) do
        values[index] = csv_escape(event[key])
    end
    return table.concat(values, ',')
end

local TICK_SECONDS   = 3
local SPAWN_BURDEN   = 30
local BASE_THRESHOLD = 30
local GAUGE_MAX      = 255
local HEATSINK_EXTRA_DECAY = { [0] = 0, [1] = 1, [2] = 2, [3] = 3 }

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

--------------------------------------------------------------------------
-- pure model core
--------------------------------------------------------------------------
local Model = {}
Model.__index = Model

-- cfg (all optional; every field is live-adjustable via model:configure{}):
--   thresh_gear     : total OVERLOAD_THRESH on the master (Horizon: 0 or 5)
--   heatsink        : true if Heatsink attachment equipped
--   frame_half_dark : true on Valoredge / Sharpshot frames
--   stat_diff       : number, or function(elementIdx, phase)->number[, context]
--                     stat difference for the maneuver's stat. nil = worst
--                     case (20); 798/799 resyncs correct it anyway. phase is
--                     'maneuver' for an actual action and 'estimate' for UI.
--                     context fields are copied into maneuver telemetry.
--   extra_decay     : additional BURDEN_DECAY beyond Heatsink (default 0)
--   gain_divisor    : integer divisor on maneuver gain (default 1;
--                     3 approximates Kenkonken SUPPRESS_OVERLOAD)
--   now             : clock function returning seconds (default os.clock)
function lib.new(cfg)
    local self = setmetatable({}, Model)
    self._telemetry_sink  = nil
    self._telemetry_error = nil
    self.stat_diff = nil
    self:configure(cfg or {})
    if self.now == nil then self.now = os.clock end

    self.gauge   = {}     -- [0..7] = number or nil (nil = unknown)
    self.quality = {}     -- [0..7] = lib.QUALITY.*
    for e = 0, 7 do
        self.gauge[e]   = nil
        self.quality[e] = lib.QUALITY.UNKNOWN
    end
    self.active            = false
    self.fire_maneuvers    = 0
    self.water_maneuvers   = 0
    self.overload_until    = 0
    self.overload_observed = nil   -- attach layer: buff-299 presence (authoritative)
    self.observed_maneuvers = {}
    for e = 0, 7 do self.observed_maneuvers[e] = 0 end
    self.last_tick         = self.now()
    return self
end

local function encode_indexed(values, unknown)
    local parts = {}
    for e = 0, 7 do
        local value = values and values[e]
        parts[#parts + 1] = e .. ':' .. (value == nil and unknown or tostring(value))
    end
    return table.concat(parts, '|')
end

-- A sink receives structured tables and must never be allowed to disrupt
-- gameplay. If it errors, telemetry disables itself and exposes the error via
-- telemetry_error(); the burden model continues normally.
function Model:_emit_telemetry(kind, fields)
    local sink = self._telemetry_sink
    if sink == nil then return end
    local event = fields or {}
    local now = self.now()
    event.clock = event.clock or now
    event.event = kind
    event.model_version = lib.VERSION
    event.threshold = event.threshold or self:threshold()
    event.decay_per_tick = event.decay_per_tick or self:decay_per_tick()
    event.fire_maneuvers = event.fire_maneuvers or self.fire_maneuvers
    event.maneuver_buffs = event.maneuver_buffs
        or encode_indexed(self.observed_maneuvers, '0')
    event.gauges = event.gauges or encode_indexed(self.gauge, '?')
    event.qualities = event.qualities or encode_indexed(self.quality, 'unknown')
    event.active = self.active
    event.overload_observed = self.overload_observed
    event.frame_half_dark = self.frame_half_dark
    event.heatsink = self.heatsink
    event.thresh_gear = self.thresh_gear
    event.gain_divisor = self.gain_divisor
    event.extra_decay = self.extra_decay
    event.last_tick = self.last_tick
    event.tick_phase = now - self.last_tick
    local ok, err = pcall(sink, event)
    if not ok then
        self._telemetry_error = tostring(err)
        self._telemetry_sink = nil
    end
end

function Model:set_telemetry_sink(sink)
    if sink ~= nil and type(sink) ~= 'function' then
        error('telemetry sink must be a function or nil')
    end
    if sink == nil then
        if self._telemetry_sink ~= nil then
            self:_emit_telemetry('telemetry_stop')
        end
        self._telemetry_sink = nil
        return
    end
    self._telemetry_sink = sink
    self._telemetry_error = nil
    self:_emit_telemetry('telemetry_start')
end

function Model:telemetry_note(note)
    self:_emit_telemetry('note', { note = tostring(note or '') })
end

function Model:telemetry_error()
    return self._telemetry_error
end

function Model:telemetry_enabled()
    return self._telemetry_sink ~= nil
end

-- Live reconfiguration: pass any subset of the cfg fields above.
function Model:configure(cfg)
    local initialized = self.gauge ~= nil
    local previous = initialized and {
        thresh_gear = self.thresh_gear,
        heatsink = self.heatsink,
        frame_half_dark = self.frame_half_dark,
        stat_diff = self.stat_diff,
        extra_decay = self.extra_decay,
        gain_divisor = self.gain_divisor,
        now = self.now,
    } or nil
    if cfg.thresh_gear     ~= nil then self.thresh_gear     = cfg.thresh_gear end
    if cfg.heatsink        ~= nil then self.heatsink        = cfg.heatsink end
    if cfg.frame_half_dark ~= nil then self.frame_half_dark = cfg.frame_half_dark end
    if cfg.stat_diff       ~= nil then self.stat_diff       = cfg.stat_diff end
    if cfg.extra_decay     ~= nil then self.extra_decay     = cfg.extra_decay end
    if cfg.gain_divisor    ~= nil then self.gain_divisor    = cfg.gain_divisor end
    if cfg.now             ~= nil then self.now             = cfg.now end
    self.thresh_gear  = self.thresh_gear  or 0
    self.heatsink     = self.heatsink     or false
    self.extra_decay  = math.max(self.extra_decay or 0, 0)
    self.gain_divisor = math.max(math.floor(self.gain_divisor or 1), 1)
    if self.frame_half_dark == nil then self.frame_half_dark = false end
    local changed = initialized and (
        previous.thresh_gear ~= self.thresh_gear
        or previous.heatsink ~= self.heatsink
        or previous.frame_half_dark ~= self.frame_half_dark
        or previous.stat_diff ~= self.stat_diff
        or previous.extra_decay ~= self.extra_decay
        or previous.gain_divisor ~= self.gain_divisor
        or previous.now ~= self.now)
    if changed then self:_emit_telemetry('configure') end
end

function Model:threshold()
    return BASE_THRESHOLD + self.thresh_gear
end

function Model:decay_per_tick()
    local d = 1 + self.extra_decay
    if self.heatsink then
        d = d + (HEATSINK_EXTRA_DECAY[clamp(self.water_maneuvers, 0, 3)] or 0)
    end
    return d
end

function Model:stat_context(elementIdx, phase)
    local sd = self.stat_diff
    if type(sd) == 'function' then
        local d, context = sd(elementIdx, phase or 'estimate')
        return d, type(context) == 'table' and context or nil
    elseif type(sd) == 'number' then
        return sd, { stat_diff = sd, stat_source = 'configured' }
    end
    return nil, nil
end

function Model:estimated_gain(elementIdx, stat_diff_override)
    local gain
    if elementIdx == lib.ELEMENT.DARK then
        gain = self.frame_half_dark and 8 or 15
    else
        local d = stat_diff_override
        if d == nil then d = self:stat_context(elementIdx, 'estimate') end
        if d == nil then gain = 20            -- worst case
        elseif d >= 4 then gain = 14
        elseif d >= 0 then gain = 19 - d
        else gain = 20 end
    end
    if self.gain_divisor > 1 then
        gain = math.floor(gain / self.gain_divisor)
    end
    return gain
end

-- Activate landed: fresh entity, all gauges 30 (exact on Horizon).
function Model:on_activate()
    for e = 0, 7 do
        self.gauge[e]   = SPAWN_BURDEN
        self.quality[e] = lib.QUALITY.EXACT
    end
    self.active          = true
    self.fire_maneuvers  = 0
    self.water_maneuvers = 0
    self.last_tick       = self.now()
    self:_emit_telemetry('activate')
    -- NOTE: overload state deliberately untouched; Overload lives on the
    -- master, not the pet.
end

-- Library loaded while the automaton is already out: state is genuinely
-- unknown. Track time/decay, report nil until 798/799 anchors an element.
function Model:on_cold_attach()
    for e = 0, 7 do
        self.gauge[e]   = nil
        self.quality[e] = lib.QUALITY.UNKNOWN
    end
    self.active    = true
    self.last_tick = self.now()
    self:_emit_telemetry('cold_attach')
end

-- Deactivate / pet death / release: server discards the pet entity.
-- Overload state is NOT cleared (master debuff).
function Model:on_deactivate()
    self.active = false
    for e = 0, 7 do
        self.gauge[e]   = nil
        self.quality[e] = lib.QUALITY.UNKNOWN
    end
    self.fire_maneuvers  = 0
    self.water_maneuvers = 0
    self:_emit_telemetry('deactivate')
end

-- A maneuver was used. Returns predicted post-gain overload chance % (or
-- nil if the gauge is unknown; the same packet's 798/799 will anchor it).
function Model:on_maneuver(elementIdx, gain_override)
    self:tick()
    local g = self.gauge[elementIdx]
    if g == nil then return nil end
    self.gauge[elementIdx] = clamp(
        g + (gain_override or self:estimated_gain(elementIdx)), 0, GAUGE_MAX)
    if self.quality[elementIdx] == lib.QUALITY.EXACT then
        self.quality[elementIdx] = lib.QUALITY.ESTIMATE
    end
    return self:chance(elementIdx)
end

-- Maneuver counts observed by the attach layer. Heatsink is Water-based;
-- Fire remains exposed for telemetry/backward-compatible consumers only.
function Model:set_fire_maneuvers(n)
    self.fire_maneuvers = clamp(n or 0, 0, 3)
end

function Model:set_water_maneuvers(n)
    self.water_maneuvers = clamp(n or 0, 0, 3)
end

-- Server chance message (798/799 param, post-gain).
-- param > 0: exact. param == 0: upper bound (thresh - 5) only.
function Model:resync(elementIdx, chance_pct)
    if chance_pct and chance_pct > 0 then
        self.gauge[elementIdx]   = clamp(chance_pct + self:threshold() - 5, 0, GAUGE_MAX)
        self.quality[elementIdx] = lib.QUALITY.EXACT
    else
        local cap = self:threshold() - 5
        local g   = self.gauge[elementIdx]
        if g == nil or g > cap then
            self.gauge[elementIdx]   = cap
            self.quality[elementIdx] = lib.QUALITY.BOUND
        end
        -- g <= cap: keep the (better or equal) existing value and quality.
    end
end

-- Message 799 fired. duration = gauge - thresh; all maneuvers stripped.
function Model:on_overload(elementIdx, chance_pct)
    if chance_pct then self:resync(elementIdx, chance_pct) end
    local g   = self.gauge[elementIdx]
    local dur = g and (g - self:threshold()) or 0
    if dur < 0 then dur = 0 end
    self.overload_until = self.now() + dur
    self.fire_maneuvers  = 0
    self.water_maneuvers = 0
    return dur
end

-- Attach layer pushes buff-299 presence here; it is authoritative.
function Model:set_overload_observed(present)
    self.overload_observed = present
end

-- Apply pending 3s decay ticks; cheap, call any frame or before queries.
function Model:tick()
    if not self.active then return end
    local t = self.now()
    local steps = math.floor((t - self.last_tick) / TICK_SECONDS)
    if steps <= 0 then return end
    self.last_tick = self.last_tick + steps * TICK_SECONDS
    local d = self:decay_per_tick() * steps
    for e = 0, 7 do
        local g = self.gauge[e]
        if g ~= nil and g > 0 then
            local dec = d
            if dec > g then dec = g end
            self.gauge[e] = g - dec
            -- Modeled decay uses a locally invented tick phase rather than
            -- Horizon's server-global phase: the value is now a projection,
            -- not a server-anchored fact. A gauge at 0 stays exact.
            if self.quality[e] == lib.QUALITY.EXACT then
                self.quality[e] = lib.QUALITY.ESTIMATE
            end
        end
    end
    self:_emit_telemetry('decay_tick', { decay_steps = steps })
end

-- Real overload chance for a post-gain gauge. Horizon still reports wire
-- params 1..5 below the threshold, but no overload roll occurs there.
function Model:chance_for_gauge(gauge)
    if gauge == nil then return nil end
    local th = self:threshold()
    if gauge <= th then return 0 end
    return clamp(gauge - th + 5, 0, 100)
end

-- Packet 798/799 reports this value even when it is 1..5 and the actual
-- overload risk is still zero. Keep it separate from chance_for_gauge().
function Model:packet_param_for_gauge(gauge)
    if gauge == nil then return nil end
    return clamp(gauge - self:threshold() + 5, 0, 255)
end

-- Overload chance % if a roll happened now; nil if gauge unknown.
function Model:chance(elementIdx)
    return self:chance_for_gauge(self.gauge[elementIdx])
end

-- Chance if a maneuver of this element were used right now (server order:
-- gain first, then roll). nil if gauge unknown. gain_override replaces the
-- model's estimate.
function Model:chance_after_maneuver(elementIdx, gain_override)
    self:tick()
    local g = self.gauge[elementIdx]
    if g == nil then return nil end
    g = clamp(g + (gain_override or self:estimated_gain(elementIdx)), 0, GAUGE_MAX)
    return self:chance_for_gauge(g)
end

-- Buff 299 is authoritative when observed; the timer is the fallback.
function Model:is_overloaded()
    if self.overload_observed ~= nil then
        return self.overload_observed
    end
    return self.now() < self.overload_until
end

-- Consistent with is_overloaded():
--   observed false        -> 0 (buff gone, timer irrelevant)
--   observed true, timer  -> timer estimate
--   observed true, none   -> nil (overloaded, duration unknown; cold attach)
--   unobserved            -> timer fallback
function Model:overload_remaining()
    local r = self.overload_until - self.now()
    if r < 0 then r = 0 end
    if self.overload_observed == false then
        return 0
    end
    if self.overload_observed == true and r == 0 then
        return nil
    end
    return r
end

-- Seconds from NOW until pure decay brings the gauge to <= target, per the
-- MODEL'S local tick phase (established at Activate/anchor time, not
-- observed from the server) and its configured decay rate. Treat as an
-- estimate with up to one tick (~3s) of phase error. nil if unknown.
function Model:seconds_to(elementIdx, target)
    self:tick()
    local g = self.gauge[elementIdx]
    if g == nil then return nil end
    if g <= target then return 0 end
    local d     = self:decay_per_tick()
    local ticks = math.ceil((g - target) / d)
    local when  = self.last_tick + ticks * TICK_SECONDS
    local r     = when - self.now()
    return r > 0 and r or 0
end

-- Returns gauge (number or nil) and quality string.
function Model:get(elementIdx)
    return self.gauge[elementIdx], self.quality[elementIdx]
end

--------------------------------------------------------------------------
-- 0x28 action packet reader
-- Widths match LSB's serializer (src/map/packets/s2c/0x028_battle2.cpp):
--   actor 32 @40 | target_count 6 @72 | reserved 4 @78 ("res_sum always 0")
--   category 4 @82 | action_id 32 @86 | recast 32 @118 | targets @150
-- Per result: resolution 3 + kind 2, animation 12, info 5, hitDistortion 2,
--   knockback 3, param 17, message 10, modifier 31, has_add 1  (= 86 bits)
--   add-effect block 37 bits; spikes block 34 bits.
-- Bits are LSB-first within each byte, bytes in stream order; offsets
-- include the 4-byte FFXI packet header (as Ashita's e.data does).
--------------------------------------------------------------------------
local function read_bits(data, startbit, len)
    local v, mult = 0, 1
    for i = 0, len - 1 do
        local b    = startbit + i
        local byte = data:byte(math.floor(b / 8) + 1)
        if byte == nil then return nil end
        if math.floor(byte / (2 ^ (b % 8))) % 2 == 1 then
            v = v + mult
        end
        mult = mult * 2
    end
    return v
end

-- Minimal parse: header + per-target message/param. Enough for maneuvers.
-- Returns nil, or { actor_id, category, action_id, target_count,
--   targets = { { id, actions = { { message, param }, ... } }, ... } }
function lib.parse_action(data)
    local act = {
        actor_id     = read_bits(data, 40, 32),
        target_count = read_bits(data, 72, 6),
        -- 4 reserved bits @78 (always 0 per LSB)
        category     = read_bits(data, 82, 4),
        action_id    = read_bits(data, 86, 32),
        -- recast 32 @118
        targets      = {},
    }
    if act.actor_id == nil or act.target_count == nil or act.action_id == nil then
        return nil
    end
    local offset = 150
    for i = 1, act.target_count do
        local tgt = { id = read_bits(data, offset, 32), actions = {} }
        local action_count = read_bits(data, offset + 32, 4)
        if tgt.id == nil or action_count == nil then return nil end
        offset = offset + 36
        for _ = 1, action_count do
            local a = {
                param   = read_bits(data, offset + 27, 17),
                message = read_bits(data, offset + 44, 10),
            }
            local has_add = read_bits(data, offset + 85, 1)
            offset = offset + 86
            if has_add == 1 then offset = offset + 37 end
            local has_spike = read_bits(data, offset, 1)
            offset = offset + 1
            if has_spike == 1 then offset = offset + 34 end
            tgt.actions[#tgt.actions + 1] = a
        end
        act.targets[i] = tgt
    end
    return act
end

--------------------------------------------------------------------------
-- attach layer: self-wiring against Ashita v4
--------------------------------------------------------------------------
-- Extra cfg keys on top of lib.new's:
--   alias         : event alias prefix (default 'burdenmodel')
--   get_player_id : function -> local player server id (default: party slot 0)
--   get_pet_index : function -> pet target index or 0/nil (default: entity
--                   manager GetPetTargetIndex on the player). Used both to
--                   cold-attach when loading mid-session and to detect pet
--                   death / release (which send no 0x28 Deactivate).
local CATEGORY_JA = 6

local function default_player_id()
    return AshitaCore:GetMemoryManager():GetParty():GetMemberServerId(0)
end

local function default_pet_index()
    local party = AshitaCore:GetMemoryManager():GetParty()
    local idx   = party:GetMemberTargetIndex(0)
    return AshitaCore:GetMemoryManager():GetEntity():GetPetTargetIndex(idx)
end

-- Poll master's buffs: elemental maneuver counts (Water drives Heatsink)
-- and buff 299.
local function poll_buffs(model)
    local ok, buffs = pcall(function()
        return AshitaCore:GetMemoryManager():GetPlayer():GetBuffs()
    end)
    if not ok or buffs == nil then return end
    local overloaded = false
    local maneuvers = {}
    for e = 0, 7 do maneuvers[e] = 0 end
    for _, b in pairs(buffs) do
        if b == lib.BUFF.OVERLOAD then overloaded = true end
        if b >= lib.BUFF.MANEUVER_FIRST and b <= lib.BUFF.MANEUVER_LAST then
            local e = b - lib.BUFF.MANEUVER_FIRST
            maneuvers[e] = maneuvers[e] + 1
        end
    end
    local signature = encode_indexed(maneuvers, '0') .. '|o:' .. tostring(overloaded)
    local changed = signature ~= model._observed_buff_signature
    model.observed_maneuvers = maneuvers
    model:set_fire_maneuvers(maneuvers[lib.ELEMENT.FIRE])
    model:set_water_maneuvers(maneuvers[lib.ELEMENT.WATER])
    model:set_overload_observed(overloaded)
    if changed then
        model._observed_buff_signature = signature
        model:_emit_telemetry('buff_state')
    end
end

function lib.attach(cfg)
    cfg = cfg or {}
    local model = lib.new(cfg)
    local alias = cfg.alias or 'burdenmodel'
    local get_player_id = cfg.get_player_id or default_player_id
    local get_pet_index = cfg.get_pet_index or default_pet_index

    model._alias_packet      = alias .. '_packet_in'
    model._alias_present     = alias .. '_present'
    model._pet_missing_since = nil

    ashita.events.register('packet_in', model._alias_packet, function(e)
        if e.id ~= 0x28 then return end
        local ok, act = pcall(lib.parse_action, e.data)
        if not ok or act == nil then
            model:_emit_telemetry('packet_parse_error', {
                note = ok and 'parse returned nil' or tostring(act),
            })
            return
        end
        if act.category ~= CATEGORY_JA then return end

        local ok2, pid = pcall(get_player_id)
        if not ok2 or act.actor_id ~= pid then return end

        local aid = act.action_id
        model:_emit_telemetry('action_packet', {
            action_id = aid,
            note = 'targets=' .. tostring(act.target_count),
        })
        if aid == lib.ABILITY.ACTIVATE then
            model:on_activate()
        elseif aid == lib.ABILITY.DEACTIVATE then
            model:on_deactivate()
        elseif aid >= lib.ABILITY.MANEUVER_FIRST and aid <= lib.ABILITY.MANEUVER_LAST then
            local elem = aid - lib.ABILITY.MANEUVER_FIRST
            if not model.active then
                model:on_cold_attach()   -- maneuver seen with no Activate: pet was already out
            end
            model:tick()
            local gauge_before, quality_before = model:get(elem)
            local stat_diff, stat_context = model:stat_context(elem, 'maneuver')
            local estimated_gain = model:estimated_gain(elem, stat_diff)
            local predicted_risk = model:on_maneuver(elem, estimated_gain)
            local gauge_predicted, quality_predicted = model:get(elem)
            local predicted_param = model:packet_param_for_gauge(gauge_predicted)
            local tgt = act.targets[1]
            local a   = tgt and tgt.actions[1]
            if a then
                if a.message == lib.MSG.OVERLOADED then
                    model:on_overload(elem, a.param)
                elseif a.message == lib.MSG.OVERLOAD_CHANCE then
                    model:resync(elem, a.param)
                end
            end
            local gauge_after, quality_after = model:get(elem)
            local server_param = a and a.param or nil
            local server_gauge = server_param ~= nil and server_param > 0
                and clamp(server_param + model:threshold() - 5, 0, GAUGE_MAX)
                or nil
            model:_emit_telemetry('maneuver_result', {
                element = lib.ELEMENT_NAME[elem] or elem,
                action_id = aid,
                message = a and a.message or nil,
                param = server_param,
                predicted_param = predicted_param,
                predicted_risk = predicted_risk,
                residual = server_param ~= nil and predicted_param ~= nil
                    and (server_param - predicted_param) or nil,
                gauge_residual = server_gauge ~= nil and gauge_predicted ~= nil
                    and (server_gauge - gauge_predicted) or nil,
                gauge_before = gauge_before,
                quality_before = quality_before,
                gauge_predicted = gauge_predicted,
                quality_predicted = quality_predicted,
                gauge_after = gauge_after,
                quality_after = quality_after,
                estimated_gain = estimated_gain,
                stat_name = stat_context and stat_context.stat_name or nil,
                master_stat = stat_context and stat_context.master_stat or nil,
                master_stat_base = stat_context and stat_context.master_stat_base or nil,
                master_stat_modifier = stat_context and stat_context.master_stat_modifier or nil,
                pet_stat = stat_context and stat_context.pet_stat or nil,
                pet_stat_base = stat_context and stat_context.pet_stat_base or nil,
                pet_stat_additional = stat_context and stat_context.pet_stat_additional or nil,
                stat_diff = stat_diff,
                stat_source = stat_context and stat_context.stat_source
                    or (elem == lib.ELEMENT.DARK and 'fixed_dark' or 'unavailable'),
                pet_stat_age = stat_context and stat_context.pet_stat_age or nil,
            })
        end
    end)

    ashita.events.register('d3d_present', model._alias_present, function()
        -- Refresh maneuver and overload buffs before applying decay.  In
        -- particular, Heatsink's rate depends on the current Water Maneuver
        -- count; ticking first would apply one frame with stale buff state.
        -- Poll unconditionally because Overload (buff 299) belongs to the
        -- master and can remain while no pet is present.
        poll_buffs(model)
        model:tick()
        local ok, petidx = pcall(get_pet_index)
        if ok then
            local pet_out = petidx ~= nil and petidx ~= 0
            if model.active then
                if not pet_out then
                    -- Detect pet death / release (no 0x28 Deactivate arrives).
                    model._pet_missing_since = model._pet_missing_since or model.now()
                    if model.now() - model._pet_missing_since > 2 then
                        model:on_deactivate()
                        model._pet_missing_since = nil
                    end
                else
                    model._pet_missing_since = nil
                end
            elseif pet_out then
                -- Loaded while the automaton was already active: unknown state.
                model:on_cold_attach()
            end
        end
    end)

    function model:detach()
        self:set_telemetry_sink(nil)
        ashita.events.unregister('packet_in',   self._alias_packet)
        ashita.events.unregister('d3d_present', self._alias_present)
    end

    return model
end

return lib
