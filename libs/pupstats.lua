--[[
pupstats.lua (v1.1) -- shared Puppetmaster burden-stat provider for Ashita v4

The server's incoming 0x44 PUP packet contains the automaton's base and
additional STR/DEX/VIT/AGI/INT/MND/CHR at offsets 0x80..0x9A.  Ashita exposes
the corresponding master base and modifier values through IPlayer.  This
module joins those two authoritative client-visible sources and snapshots the
relevant pair when an outgoing Maneuver request is sent, before an aftercast
gear swap can change the master's live values.

Usage:
    local pupstats = require('pupstats')
    local stats = pupstats.attach({ alias = 'myaddon_pupstats' })
    local diff, context = stats:stat_diff(element_index, 'maneuver')
    -- context includes both base/additional values and their totals.
    local has_heatsink = stats:has_attachment('Heatsink')
    stats:detach()

Element indices match burdenmodel.lua: Fire=0 through Dark=7. Dark burden has
its own fixed rule and therefore has no associated stat.
]]

local lib = {}
lib.VERSION = '1.1'

local PUP_JOB_ID = 18
local ACTION_PACKET = 0x01A
local JOB_INFO_EXTRA_PACKET = 0x044
local ZONE_IN_PACKET = 0x00A
local ZONE_OUT_PACKET = 0x00B
local CATEGORY_JOB_ABILITY = 0x09
local MANEUVER_FIRST = 141
local MANEUVER_LAST = 148
local SNAPSHOT_MAX_AGE = 5
local ATTACHMENT_FIRST_OFFSET = 0x0A
local ATTACHMENT_SLOT_COUNT = 12
local ATTACHMENT_RESOURCE_OFFSET = 0x2100

lib.STAT = {
    STR = 0, DEX = 1, VIT = 2, AGI = 3, INT = 4, MND = 5, CHR = 6,
}

lib.STAT_NAME = {
    [0] = 'STR', [1] = 'DEX', [2] = 'VIT', [3] = 'AGI',
    [4] = 'INT', [5] = 'MND', [6] = 'CHR',
}

lib.ELEMENT_NAME = {
    [0] = 'Fire', [1] = 'Ice', [2] = 'Wind', [3] = 'Earth',
    [4] = 'Thunder', [5] = 'Water', [6] = 'Light', [7] = 'Dark',
}

-- Fire/STR, Ice/INT, Wind/AGI, Earth/VIT, Thunder/DEX, Water/MND,
-- Light/CHR. Dark uses the fixed Dark-burden rule.
lib.ELEMENT_STAT = {
    [0] = lib.STAT.STR,
    [1] = lib.STAT.INT,
    [2] = lib.STAT.AGI,
    [3] = lib.STAT.VIT,
    [4] = lib.STAT.DEX,
    [5] = lib.STAT.MND,
    [6] = lib.STAT.CHR,
    [7] = nil,
}

local PET_BASE_OFFSET = {
    [lib.STAT.STR] = 0x80,
    [lib.STAT.DEX] = 0x84,
    [lib.STAT.VIT] = 0x88,
    [lib.STAT.AGI] = 0x8C,
    [lib.STAT.INT] = 0x90,
    [lib.STAT.MND] = 0x94,
    [lib.STAT.CHR] = 0x98,
}

local function read_u16(data, offset)
    if data == nil or #data < offset + 2 then return nil end
    local lo, hi = data:byte(offset + 1, offset + 2)
    if lo == nil or hi == nil then return nil end
    return lo + hi * 256
end

local function default_now()
    return os.clock()
end

local Provider = {}
Provider.__index = Provider

function lib.new(cfg)
    cfg = cfg or {}
    local self = setmetatable({}, Provider)
    self.now = cfg.now or default_now
    self.pet_base = {}
    self.pet_additional = {}
    self.pet_total = {}
    self.pet_updated = nil
    self.automaton_head = nil
    self.automaton_frame = nil
    self.attachment_ids = {}
    self.attachment_names = {}
    self.pending = {}
    self.last_context = {}
    return self
end

function Provider:clear()
    self.pet_base = {}
    self.pet_additional = {}
    self.pet_total = {}
    self.pet_updated = nil
    self.automaton_head = nil
    self.automaton_frame = nil
    self.attachment_ids = {}
    self.attachment_names = {}
    self.pending = {}
    self.last_context = {}
end

-- Parses a main-job PUP 0x44. Returns true only when a complete stat block was
-- accepted. The packet values are exactly what the FFXI client displays.
function Provider:on_job_info(data)
    if data == nil or #data < 0x9C then return false end
    local job = data:byte(0x04 + 1)
    local is_subjob = data:byte(0x05 + 1)
    if job ~= PUP_JOB_ID or is_subjob ~= 0 then return false end

    local base = {}
    local additional = {}
    local total = {}
    for stat_index = 0, 6 do
        local offset = PET_BASE_OFFSET[stat_index]
        local b = read_u16(data, offset)
        local a = read_u16(data, offset + 2)
        if b == nil or a == nil then return false end
        base[stat_index] = b
        additional[stat_index] = a
        total[stat_index] = b + a
    end

    self.pet_base = base
    self.pet_additional = additional
    self.pet_total = total
    self.pet_updated = self.now()
    self.automaton_head = data:byte(0x08 + 1)
    self.automaton_frame = data:byte(0x09 + 1)
    self.attachment_ids = {}
    self.attachment_names = {}
    for slot = 1, ATTACHMENT_SLOT_COUNT do
        local attachment_id = data:byte(ATTACHMENT_FIRST_OFFSET + slot)
        if attachment_id ~= nil and attachment_id ~= 0 then
            self.attachment_ids[slot] = attachment_id
        end
    end
    return true
end

local function resource_name(resource)
    if resource == nil then return nil end
    local name = resource.Name
    if type(name) == 'string' then return name end
    if name ~= nil then
        local ok, english = pcall(function() return name[1] end)
        if ok and type(english) == 'string' then return english end
    end
    return nil
end

function Provider:_attachment_name(slot)
    local cached = self.attachment_names[slot]
    if cached ~= nil then return cached end
    local attachment_id = self.attachment_ids[slot]
    if attachment_id == nil then return nil end
    local ok, name = pcall(function()
        local manager = AshitaCore:GetResourceManager()
        if manager == nil then return nil end
        return resource_name(manager:GetItemById(
            ATTACHMENT_RESOURCE_OFFSET + attachment_id))
    end)
    if not ok or name == nil then return nil end
    self.attachment_names[slot] = name
    return name
end

-- Attachment IDs live in the same main-job PUP 0x44 as the stat block. Names
-- are resolved lazily so the pure parser remains usable in tests and during
-- early load, before Ashita's resource manager is ready.
function Provider:has_attachment(wanted_name)
    wanted_name = string.lower(tostring(wanted_name or ''))
    if wanted_name == '' then return false end
    for slot = 1, ATTACHMENT_SLOT_COUNT do
        local name = self:_attachment_name(slot)
        if name ~= nil and string.lower(name) == wanted_name then
            return true
        end
    end
    return false
end

function Provider:attachments()
    local result = {}
    for slot = 1, ATTACHMENT_SLOT_COUNT do
        local attachment_id = self.attachment_ids[slot]
        if attachment_id ~= nil then
            result[#result + 1] = {
                slot = slot,
                id = attachment_id,
                name = self:_attachment_name(slot),
            }
        end
    end
    return result
end

function Provider:_master_stat(stat_index)
    local ok, base, modifier = pcall(function()
        local player = AshitaCore:GetMemoryManager():GetPlayer()
        if player == nil then return nil, nil end
        return player:GetStat(stat_index), player:GetStatModifier(stat_index)
    end)
    if not ok or base == nil then return nil, nil, nil end
    modifier = modifier or 0
    return base, modifier, base + modifier
end

function Provider:_capture(element_index, source)
    local stat_index = lib.ELEMENT_STAT[element_index]
    if stat_index == nil then
        return {
            element = element_index,
            stat_source = 'fixed_dark',
            captured_at = self.now(),
        }
    end

    local master_base, master_modifier, master_total = self:_master_stat(stat_index)
    local pet_base = self.pet_base[stat_index]
    local pet_additional = self.pet_additional[stat_index]
    local pet_total = self.pet_total[stat_index]
    local captured_at = self.now()
    local context = {
        element = element_index,
        stat_index = stat_index,
        stat_name = lib.STAT_NAME[stat_index],
        master_stat_base = master_base,
        master_stat_modifier = master_modifier,
        master_stat = master_total,
        pet_stat_base = pet_base,
        pet_stat_additional = pet_additional,
        pet_stat = pet_total,
        stat_diff = master_total ~= nil and pet_total ~= nil
            and (master_total - pet_total) or nil,
        stat_source = source or 'live',
        captured_at = captured_at,
        pet_stat_age = self.pet_updated ~= nil
            and math.max(0, captured_at - self.pet_updated) or nil,
    }
    return context
end

function Provider:snapshot_maneuver(element_index)
    local context = self:_capture(element_index, 'outgoing_snapshot')
    self.pending[element_index] = context
    self.last_context[element_index] = context
    return context
end

function Provider:_complete_snapshot(context)
    local stat_index = context and context.stat_index or nil
    if stat_index == nil then return context end
    local completed_pet = false
    local completed_master = false
    if context.pet_stat == nil and self.pet_total[stat_index] ~= nil then
        context.pet_stat_base = self.pet_base[stat_index]
        context.pet_stat_additional = self.pet_additional[stat_index]
        context.pet_stat = self.pet_total[stat_index]
        context.pet_stat_age = self.pet_updated ~= nil
            and math.max(0, self.now() - self.pet_updated) or nil
        completed_pet = true
    end
    if context.master_stat == nil then
        local base, modifier, total = self:_master_stat(stat_index)
        context.master_stat_base = base
        context.master_stat_modifier = modifier
        context.master_stat = total
        completed_master = total ~= nil
    end
    context.stat_diff = context.master_stat ~= nil and context.pet_stat ~= nil
        and (context.master_stat - context.pet_stat) or nil
    if completed_master then
        context.stat_source = 'incoming_fallback'
    elseif completed_pet then
        context.stat_source = 'outgoing_snapshot_completed'
    end
    return context
end

-- phase='maneuver' consumes a recent outgoing snapshot. Other callers receive
-- a live view, suitable for UI projections between actions.
function Provider:stat_diff(element_index, phase)
    local context = nil
    if phase == 'maneuver' then
        context = self.pending[element_index]
        self.pending[element_index] = nil
        if context ~= nil and self.now() - context.captured_at > SNAPSHOT_MAX_AGE then
            context = nil
        elseif context ~= nil then
            context = self:_complete_snapshot(context)
        end
    end
    if context == nil then
        context = self:_capture(element_index,
            phase == 'maneuver' and 'incoming_fallback' or 'live')
    end
    self.last_context[element_index] = context
    return context.stat_diff, context
end

function Provider:get_context(element_index)
    return self:_capture(element_index, 'live')
end

-- Compact, addon-neutral diagnostic groups for chat status commands.
function Provider:summary_groups(group_size)
    group_size = math.max(math.floor(tonumber(group_size) or 4), 1)
    local groups = {}
    local parts = {}
    for element_index = 0, 6 do
        local context = self:get_context(element_index)
        if context.master_stat ~= nil and context.pet_stat ~= nil then
            parts[#parts + 1] = ('%s %s %d-%d=%+d'):format(
                lib.ELEMENT_NAME[element_index], context.stat_name,
                context.master_stat, context.pet_stat, context.stat_diff)
        else
            parts[#parts + 1] = ('%s %s unavailable'):format(
                lib.ELEMENT_NAME[element_index], context.stat_name)
        end
        if #parts == group_size then
            groups[#groups + 1] = table.concat(parts, ' | ')
            parts = {}
        end
    end
    if #parts > 0 then groups[#groups + 1] = table.concat(parts, ' | ') end
    return groups
end

function lib.attach(cfg)
    cfg = cfg or {}
    local provider = lib.new(cfg)
    local alias = cfg.alias or 'pupstats'
    provider._alias_in = alias .. '_packet_in'
    provider._alias_out = alias .. '_packet_out'

    ashita.events.register('packet_in', provider._alias_in, function(e)
        if e.id == ZONE_IN_PACKET or e.id == ZONE_OUT_PACKET then
            provider:clear()
            return
        end
        if e.id ~= JOB_INFO_EXTRA_PACKET then return end
        provider:on_job_info(e.data_modified or e.data_raw or e.data)
    end)

    ashita.events.register('packet_out', provider._alias_out, function(e)
        if e.id ~= ACTION_PACKET then return end
        local data = e.data_modified or e.data
        if data == nil or #data < 0x0E then return end
        local category = read_u16(data, 0x0A)
        local action_id = read_u16(data, 0x0C)
        if category ~= CATEGORY_JOB_ABILITY
            or action_id == nil
            or action_id < MANEUVER_FIRST
            or action_id > MANEUVER_LAST then
            return
        end
        provider:snapshot_maneuver(action_id - MANEUVER_FIRST)
    end)

    function provider:detach()
        ashita.events.unregister('packet_in', self._alias_in)
        ashita.events.unregister('packet_out', self._alias_out)
    end

    return provider
end

return lib
