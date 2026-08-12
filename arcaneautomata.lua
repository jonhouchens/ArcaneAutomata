addon.name      = 'arcaneautomata';
addon.author    = 'Koruru';
addon.version   = '1.0.1';
addon.desc      = 'Arcane elemental automata for Puppetmaster maneuvers.';

require 'common';

local actionpacket = require 'actionpacket';
local chat         = require 'chat';
local d3d8         = require 'd3d8';
local ffi          = require 'ffi';
local imgui        = require 'imgui';
local settings     = require 'settings';

local DISPLAY_NAME = 'Arcane Automata';
local C = ffi.C;
local PUP_JOB_ID = 18;
local MANEUVER_DURATION = 60;
local MANEUVER_MIN_ID = 141;
local MANEUVER_MAX_ID = 148;
local MANEUVER_RESOURCE_OFFSET = 512;
local MANEUVER_RECAST_SECONDS = 10;
local MANEUVER_SYNC_TIMEOUT = 2.5;
local MANEUVER_ABORT_TIMEOUT = 5.0;
local OVERLOAD_BUFF_ID = 299;
local ORIGIN_WORLD_LIFT = 0.10;
local TAU = math.pi * 2;
local TRANSITION_SECONDS = 0.28;
local ENGAGEMENT_BLEND_SECONDS = 0.20;
local DEPLOY_BLEND_SECONDS = 0.24;

local elements = {
    [141] = { name = 'Fire',    buff = 300, color = { 0.93, 0.27, 0.16, 1.00 } },
    [142] = { name = 'Ice',     buff = 301, color = { 0.39, 0.76, 1.00, 1.00 } },
    [143] = { name = 'Wind',    buff = 302, color = { 0.31, 0.88, 0.54, 1.00 } },
    [144] = { name = 'Earth',   buff = 303, color = { 0.76, 0.55, 0.27, 1.00 } },
    [145] = { name = 'Thunder', buff = 304, color = { 0.77, 0.47, 1.00, 1.00 } },
    [146] = { name = 'Water',   buff = 305, color = { 0.19, 0.57, 0.98, 1.00 } },
    [147] = { name = 'Light',   buff = 306, color = { 1.00, 0.91, 0.38, 1.00 } },
    [148] = { name = 'Dark',    buff = 307, color = { 0.59, 0.42, 0.75, 1.00 } },
};

-- Okabe-Ito-inspired colors, extended with a muted violet for Dark.
local colorblind_colors = {
    Fire    = { 0.90, 0.62, 0.00, 1.00 },
    Ice     = { 0.34, 0.71, 0.91, 1.00 },
    Wind    = { 0.00, 0.62, 0.45, 1.00 },
    Earth   = { 0.94, 0.89, 0.26, 1.00 },
    Thunder = { 0.80, 0.48, 0.66, 1.00 },
    Water   = { 0.00, 0.45, 0.70, 1.00 },
    Light   = { 0.96, 0.90, 0.65, 1.00 },
    Dark    = { 0.48, 0.40, 0.64, 1.00 },
};

local by_buff = {};
local by_name = {};
for ability_id = MANEUVER_MIN_ID, MANEUVER_MAX_ID do
    local element = elements[ability_id];
    element.ability = ability_id;
    by_buff[element.buff] = element;
    by_name[string.lower(element.name)] = element;
end

local defaults = T{
    enabled = true,
    style = 'crown',
    radius = 55,
    height = 35,
    speed = 0.15,
    scale = 1.0,
    offset_y = -120,
    idle_offset_y = 18,
    timers = true,
    recast_ring = true,
    effects = true,
    transitions = true,
    smoothing = 0.12,
    burden = true,
    lattice = true,
    deploy_focus = true,
    deploy_style = 'seals',
    deploy_orbit = true,
    deploy_orbit_speed = 0.06,
    confirmation_flash = true,
    icon_mode = 'runes',
    colorblind = false,
    fallback = false,
    safearea = true,
    autohide = true,
    test_mode = false,
    test_count = 3,
    test_risk = 'LOW',
    test_deployed = false,
    test_elements = T{ 'Fire', 'Ice', 'Thunder' },
};

local visual_presets = {
    -- Captured from Koruru's live Tarutaru profile on 2026-08-11.
    taru = {
        style = 'crown', radius = 55, height = 35, speed = 0.15,
        scale = 1.15, offset_y = -100, idle_offset_y = 90,
        effects = true, timers = true, safearea = false, fallback = false,
    },
    compact = {
        style = 'crown', radius = 44, height = 28, speed = 0.10,
        scale = 0.92, effects = true,
    },
    cinematic = {
        style = 'orbit', radius = 72, height = 44, speed = 0.11,
        scale = 1.22, effects = true, smoothing = 0.16,
    },
};

-- The outer recast mote is the precise clock. Lattice motion instead reflects
-- the worst current burden state across the three-maneuver formation.
local lattice_risk_rank = { LOW = 1, WARM = 2, DANGER = 3, OVERLOAD = 4 };
local lattice_profiles = {
    LOW = {
        circuit_speed = 0.60, pulse_speed = 1.50, intensity = 1.00,
        width = 1.00, tint_mix = 1.00, tint = { 0.30, 0.78, 0.72, 1.00 },
    },
    WARM = {
        circuit_speed = 0.86, pulse_speed = 2.40, intensity = 1.15,
        width = 1.08, tint_mix = 1.00, tint = { 1.00, 0.70, 0.20, 1.00 },
    },
    DANGER = {
        circuit_speed = 1.50, pulse_speed = 4.00, intensity = 1.34,
        width = 1.20, tint_mix = 1.00, tint = { 1.00, 0.34, 0.07, 1.00 },
    },
    OVERLOAD = {
        circuit_speed = 0.00, pulse_speed = 8.00, intensity = 1.48,
        width = 1.30, tint_mix = 1.00, tint = { 1.00, 0.12, 0.08, 1.00 },
    },
};

local state = {
    settings = settings.load(defaults),
    slots = {},
    fading_slots = {},
    element_chances = {},
    overload_flash = nil,
    confirmation_flash = nil,
    last_sync = -1,
    last_action = -10,
    recast_was_active = false,
    recast_ready_at = -10,
    pending_sync = nil,
    was_pup = false,
    was_alive = false,
    was_zoning = false,
    last_render_error = nil,
    anchor_x = nil,
    anchor_y = nil,
    anchor_time = 0,
    idle_blend = nil,
    engagement_time = 0,
    deploy_blend = nil,
    deploy_time = 0,
};

-- These signatures are already used by the installed Ashita UI addons. They
-- fail open if a future client update makes either signature unavailable.
local event_system_pointer = ashita.memory.find(
    'FFXiMain.dll', 0,
    'A0????????84C0741AA1????????85C0741166A1????????663B05????????0F94C0C3', 0, 0);
local interface_hidden_pointer = ashita.memory.find(
    'FFXiMain.dll', 0,
    '8B4424046A016A0050B9????????E8????????F6D81BC040C3', 0, 0);

local function clamp(value, low, high)
    return math.max(low, math.min(high, value));
end

local function is_finite(value)
    return value ~= nil and value == value and value ~= math.huge and value ~= -math.huge;
end

local function clock_seconds()
    local stamp = ashita.time.clock();
    if (stamp ~= nil and stamp.ms ~= nil) then
        return stamp.ms / 1000;
    end
    return os.clock();
end

local function ensure_settings_shape()
    local s = state.settings;
    -- Remove the retired recommendation-orb settings from older profiles.
    s.ghost = nil;
    s.ghost_plan = nil;
    s.ghost_refresh_at = nil;
    s.enabled = s.enabled ~= false;
    s.style = s.style == 'orbit' and 'orbit' or 'crown';
    s.radius = clamp(tonumber(s.radius) or 55, 20, 180);
    s.height = clamp(tonumber(s.height) or 35, 10, 140);
    s.speed = clamp(tonumber(s.speed) or 0.15, 0, 1.0);
    s.scale = clamp(tonumber(s.scale) or 1.0, 0.5, 2.5);
    s.offset_y = clamp(tonumber(s.offset_y) or -120, -500, 500);
    s.idle_offset_y = clamp(tonumber(s.idle_offset_y) or 18, -200, 200);
    s.timers = s.timers ~= false;
    s.recast_ring = s.recast_ring ~= false;
    s.effects = s.effects ~= false;
    s.transitions = s.transitions ~= false;
    s.smoothing = clamp(tonumber(s.smoothing) or 0.12, 0, 0.50);
    s.burden = s.burden ~= false;
    s.lattice = s.lattice ~= false;
    s.deploy_focus = s.deploy_focus ~= false;
    s.deploy_style = s.deploy_style == 'chevrons' and 'chevrons' or 'seals';
    s.deploy_orbit = s.deploy_orbit ~= false;
    s.deploy_orbit_speed = clamp(
        tonumber(s.deploy_orbit_speed) or 0.06, 0.01, 0.25);
    s.confirmation_flash = s.confirmation_flash ~= false;
    -- The retired spell-art mode migrates to the new texture-free crests.
    if (s.icon_mode == 'spells' or s.icon_mode == 'crests') then
        s.icon_mode = 'crests';
    elseif (s.icon_mode == 'mechanical') then
        s.icon_mode = 'mechanical';
    else
        s.icon_mode = 'runes';
    end
    s.colorblind = s.colorblind == true;
    s.fallback = s.fallback == true;
    s.safearea = s.safearea ~= false;
    s.autohide = s.autohide ~= false;
    s.test_mode = s.test_mode == true;
    s.test_count = math.floor(clamp(tonumber(s.test_count) or 3, 1, 3));
    s.test_deployed = s.test_deployed == true;
    s.test_risk = string.upper(tostring(s.test_risk or 'LOW'));
    if (lattice_profiles[s.test_risk] == nil) then
        s.test_risk = 'LOW';
    end
    s.test_elements = s.test_elements or T{ 'Fire', 'Ice', 'Thunder' };
    local fallback_elements = { 'Fire', 'Ice', 'Thunder' };
    for index = 1, 3 do
        local element = by_name[string.lower(
            tostring(s.test_elements[index] or fallback_elements[index]))];
        s.test_elements[index] = element ~= nil
            and element.name or fallback_elements[index];
    end
end

ensure_settings_shape();

local function message(text)
    print(chat.header(DISPLAY_NAME):append(chat.message(text)));
end

local function error_message(text)
    print(chat.header(DISPLAY_NAME):append(chat.error(text)));
end

local function clear_slots()
    state.slots = {};
    state.fading_slots = {};
    state.element_chances = {};
    state.overload_flash = nil;
    state.confirmation_flash = nil;
    state.pending_sync = nil;
    state.recast_was_active = false;
    state.recast_ready_at = -10;
    state.anchor_x = nil;
    state.anchor_y = nil;
    state.anchor_time = 0;
    state.idle_blend = nil;
    state.engagement_time = 0;
    state.deploy_blend = nil;
    state.deploy_time = 0;
end

local function ensure_test_slots(force)
    if (not state.settings.test_mode) then
        return;
    end

    local now = clock_seconds();
    local count = state.settings.test_count;
    local rebuild = force == true or #state.slots ~= count;
    if (not rebuild) then
        for index = 1, count do
            local slot = state.slots[index];
            local element = by_name[string.lower(
                state.settings.test_elements[index] or '')];
            if (slot == nil or not slot.test_preview or element == nil
                or slot.ability ~= element.ability or slot.expires <= now) then
                rebuild = true;
                break;
            end
        end
    end
    if (not rebuild) then
        return;
    end

    state.slots = {};
    state.fading_slots = {};
    state.pending_sync = nil;
    for index = 1, count do
        local element = by_name[string.lower(
            state.settings.test_elements[index])];
        table.insert(state.slots, {
            name = element.name,
            ability = element.ability,
            started = now,
            expires = now + MANEUVER_DURATION,
            approximate = false,
            test_preview = true,
        });
    end
    state.last_sync = now;
end

local function is_event_system_active()
    if (event_system_pointer == nil or event_system_pointer == 0) then
        return false;
    end
    local ok, active = pcall(function()
        local pointer = ashita.memory.read_uint32(event_system_pointer + 1);
        return pointer ~= nil and pointer ~= 0
            and ashita.memory.read_uint8(pointer) == 1;
    end);
    return ok and active == true;
end

local function is_interface_hidden()
    if (interface_hidden_pointer == nil or interface_hidden_pointer == 0) then
        return false;
    end
    local ok, hidden = pcall(function()
        local pointer = ashita.memory.read_uint32(interface_hidden_pointer + 10);
        return pointer ~= nil and pointer ~= 0
            and ashita.memory.read_uint8(pointer + 0xB4) == 1;
    end);
    return ok and hidden == true;
end

local function is_first_person()
    local ok, first_person = pcall(function()
        local manager = AshitaCore:GetMemoryManager():GetAutoFollow();
        return manager ~= nil and manager:GetIsFirstPersonCamera() ~= 0;
    end);
    return ok and first_person == true;
end

local function should_auto_hide()
    if (not state.settings.autohide) then
        return false;
    end
    local player = GetPlayerEntity();
    return (player ~= nil and player.StatusServer == 4)
        or is_event_system_active()
        or is_interface_hidden()
        or is_first_person();
end

local function get_player_state()
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    local entity = GetPlayerEntity();
    if (player == nil or entity == nil) then
        return false, false, true;
    end

    local is_pup = player:GetMainJob() == PUP_JOB_ID;
    local alive = (entity.HPPercent or 0) > 0;
    local zoning = player:GetIsZoning() ~= 0;
    local engaged = entity.Status == 1;
    return is_pup, alive, zoning, engaged;
end

local function automaton_is_deployed()
    local player = GetPlayerEntity();
    if (player == nil or player.PetTargetIndex == nil
        or player.PetTargetIndex == 0) then
        return false;
    end
    local pet = GetEntity(player.PetTargetIndex);
    return pet ~= nil and (pet.Status or 0) == 1;
end

local function current_buff_counts()
    local counts = {};
    local overloaded = false;
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if (player == nil) then
        return counts, overloaded;
    end

    for _, buff_id in pairs(player:GetBuffs()) do
        local element = by_buff[buff_id];
        if (buff_id == OVERLOAD_BUFF_ID) then
            overloaded = true;
        elseif (element ~= nil) then
            counts[element.name] = (counts[element.name] or 0) + 1;
        end
    end
    return counts, overloaded;
end

local function game_maneuver_recast()
    local resource = AshitaCore:GetResourceManager():GetAbilityById(
        MANEUVER_MIN_ID + MANEUVER_RESOURCE_OFFSET);
    if (resource == nil) then
        return 0;
    end

    local recasts = AshitaCore:GetMemoryManager():GetRecast();
    if (recasts == nil) then
        return 0;
    end
    for index = 0, 31 do
        if (recasts:GetAbilityTimerId(index) == resource.RecastTimerId) then
            return math.max(0, recasts:GetAbilityTimer(index) / 60);
        end
    end
    return 0;
end

local function maneuver_recast()
    local local_recast = math.max(
        0, MANEUVER_RECAST_SECONDS - (clock_seconds() - state.last_action));
    if (state.settings.test_mode) then
        return local_recast;
    end
    return math.max(game_maneuver_recast(), local_recast);
end

local function tracked_counts()
    local counts = {};
    for _, slot in ipairs(state.slots) do
        counts[slot.name] = (counts[slot.name] or 0) + 1;
    end
    return counts;
end

local function maneuver_count_total(counts)
    local count = 0;
    for _, value in pairs(counts) do
        count = count + value;
    end
    return count;
end

local function maneuver_counts_equal(left, right)
    for ability_id = MANEUVER_MIN_ID, MANEUVER_MAX_ID do
        local name = elements[ability_id].name;
        if ((left[name] or 0) ~= (right[name] or 0)) then
            return false;
        end
    end
    return true;
end

local function begin_layout_transition(now)
    if (not state.settings.transitions) then
        return;
    end
    now = now or clock_seconds();
    for _, slot in ipairs(state.slots) do
        if (slot.last_x ~= nil and slot.last_y ~= nil) then
            slot.layout_from_x = slot.last_x;
            slot.layout_from_y = slot.last_y;
            slot.layout_from_depth = slot.last_depth or 0;
            slot.layout_started = now;
        end
    end
end

local function fade_slot(slot, now)
    if (slot == nil or not state.settings.transitions) then
        return;
    end
    slot.removed_at = now or clock_seconds();
    table.insert(state.fading_slots, slot);
    while (#state.fading_slots > 3) do
        table.remove(state.fading_slots, 1);
    end
end

local function retire_slot(index, now)
    local slot = table.remove(state.slots, index);
    begin_layout_transition(now);
    fade_slot(slot, now);
end

local function earliest_slot_index(name)
    local selected_index = nil;
    local selected_expiry = math.huge;
    for index, slot in ipairs(state.slots) do
        if ((name == nil or slot.name == name)
            and slot.expires < selected_expiry) then
            selected_index = index;
            selected_expiry = slot.expires;
        end
    end
    return selected_index;
end

local function record_maneuver(element, approximate, started)
    if (element == nil) then
        return nil;
    end
    local now = clock_seconds();
    local action_started = started or now;
    local slot = {
        name = element.name,
        ability = element.ability,
        started = action_started,
        appeared = now,
        expires = action_started + MANEUVER_DURATION,
        approximate = approximate == true,
    };

    if (#state.slots >= 3) then
        local replace_index = earliest_slot_index();
        local replaced = state.slots[replace_index];
        if (replaced.name == element.name) then
            -- Refresh the matching visual in place. Its timer and activation
            -- ripple restart, but the orb itself never disappears or moves.
            replaced.started = slot.started;
            replaced.expires = slot.expires;
            replaced.approximate = slot.approximate;
            return replaced;
        end

        -- Crossfade a different element in the exact slot that the game
        -- replaces, keeping the other two visuals completely stable.
        fade_slot(replaced, now);
        state.slots[replace_index] = slot;
        return slot;
    end

    begin_layout_transition(now);
    table.insert(state.slots, slot);
    return slot;
end

local function apply_pending_maneuver(pending, actual, now)
    local before = pending.before_counts;
    local element = pending.element;
    local unchanged = maneuver_counts_equal(actual, before);
    local before_total = maneuver_count_total(before);
    local slot = nil;

    if (before_total >= 3 and unchanged) then
        -- Counts cannot identify which duplicate was refreshed. The server
        -- result proves that an instance of this element was replaced, so
        -- refresh the earliest matching visual and leave every other element
        -- untouched.
        local index = earliest_slot_index(element.name);
        slot = index ~= nil and state.slots[index] or nil;
        if (slot ~= nil) then
            slot.started = pending.seen;
            slot.expires = pending.seen + MANEUVER_DURATION;
            slot.approximate = false;
        end
    elseif (before_total >= 3) then
        local replaced_name = nil;
        for ability_id = MANEUVER_MIN_ID, MANEUVER_MAX_ID do
            local name = elements[ability_id].name;
            if ((before[name] or 0) > (actual[name] or 0)) then
                replaced_name = name;
                break;
            end
        end

        local index = replaced_name ~= nil
            and earliest_slot_index(replaced_name) or nil;
        if (index ~= nil) then
            local replaced = state.slots[index];
            slot = {
                name = element.name,
                ability = element.ability,
                started = pending.seen,
                appeared = now,
                expires = pending.seen + MANEUVER_DURATION,
                approximate = false,
            };
            fade_slot(replaced, now);
            state.slots[index] = slot;
        end
    end

    if (slot == nil) then
        slot = record_maneuver(element, false, pending.seen);
    end
    if (state.settings.confirmation_flash and slot ~= nil) then
        state.confirmation_flash = {
            slot = slot,
            started = now,
        };
    end
end

local function confirm_maneuver_slot(slot, now)
    if (state.settings.confirmation_flash and slot ~= nil) then
        state.confirmation_flash = {
            slot = slot,
            started = now,
        };
    end
end

local function apply_immediate_maneuver(element, before_counts, now)
    local before_total = maneuver_count_total(before_counts);
    if (before_total < 3) then
        -- A successful action below the maneuver cap can only add a new
        -- instance, so there is no replacement ambiguity to reconcile.
        return record_maneuver(element, false, now);
    end

    local replace_index = earliest_slot_index();
    local replaced = replace_index ~= nil and state.slots[replace_index] or nil;
    if (replaced ~= nil and not replaced.approximate) then
        -- Exact timers identify the instance the game will replace. Apply the
        -- successful action immediately and let record_maneuver either refresh
        -- a matching orb or replace a different element in the same position.
        return record_maneuver(element, false, now);
    end

    return nil;
end

local function reconcile_slots(force)
    local now = clock_seconds();
    if (not force and now - state.last_sync < 0.25) then
        return;
    end
    state.last_sync = now;

    local actual = current_buff_counts();
    local pending = state.pending_sync;
    if (not force and pending ~= nil) then
        local elapsed = now - pending.seen;
        local before = pending.before_counts;
        local before_total = maneuver_count_total(before);
        local expected_total = math.min(3, before_total + 1);
        local actual_total = maneuver_count_total(actual);
        local new_count_increased = (actual[pending.element.name] or 0)
            > (before[pending.element.name] or 0);
        local observed_complete = actual_total == expected_total
            and new_count_increased;
        local unchanged = maneuver_counts_equal(actual, before);
        local unchanged_refresh = unchanged and before_total >= 3
            and (before[pending.element.name] or 0) > 0;

        if (observed_complete) then
            -- Require the complete result on two reconciliation passes. This
            -- prevents a torn memory read from committing a plausible but
            -- transient three-buff snapshot.
            if (pending.observed_counts == nil
                or not maneuver_counts_equal(
                    actual, pending.observed_counts)) then
                pending.observed_counts = actual;
                pending.observed_at = now;
                return;
            elseif (now - pending.observed_at < 0.20) then
                return;
            end
        elseif (not unchanged_refresh or elapsed < MANEUVER_SYNC_TIMEOUT) then
            pending.observed_counts = nil;
            pending.observed_at = nil;
            -- Ignore both the unchanged pre-action snapshot and any partial
            -- remove/add snapshots. Nothing visual changes until the complete
            -- post-action state is available.
            if (elapsed < MANEUVER_ABORT_TIMEOUT) then
                return;
            end
            -- A successful action should settle well before this point. If it
            -- does not, abandon the transaction and let ordinary buff
            -- reconciliation recover from the one current snapshot.
            state.pending_sync = nil;
            pending = nil;
        end

        if (pending ~= nil) then
            state.pending_sync = nil;
            apply_pending_maneuver(pending, actual, now);
            return;
        end
    elseif (not force and now - state.last_action < 1.0) then
        -- Overload failures have no provisional maneuver, but their action can
        -- still arrive before the client buff list settles.
        return;
    end
    local tracked = tracked_counts();

    -- Buff loss is authoritative. Remove the earliest-expiring matching
    -- instance first so duplicate timers remain aligned with replacement rules.
    for name, count in pairs(tracked) do
        local excess = count - (actual[name] or 0);
        while (excess > 0) do
            local index = earliest_slot_index(name);
            if (index ~= nil) then
                retire_slot(index, now);
            end
            excess = excess - 1;
        end
    end

    tracked = tracked_counts();
    -- The original activation order cannot be recovered on addon load. Use a
    -- deterministic elemental order and mark every discovered timer approximate.
    for ability_id = MANEUVER_MIN_ID, MANEUVER_MAX_ID do
        local element = elements[ability_id];
        local missing = (actual[element.name] or 0) - (tracked[element.name] or 0);
        while (missing > 0) do
            record_maneuver(element, true);
            missing = missing - 1;
        end
    end
end

local function record_overload_chance(element, chance)
    if (element == nil) then
        return;
    end
    local now = clock_seconds();
    if (chance ~= nil) then
        state.element_chances[element.name] = {
            chance = clamp(tonumber(chance) or 0, 0, 100),
            time = now,
        };
    end
end

local function burden_risk(name, overloaded)
    if (overloaded == nil) then
        local _, current_overload = current_buff_counts();
        overloaded = current_overload;
    end
    if (overloaded) then
        return 'OVERLOAD', 100;
    end

    local snapshot = state.element_chances[name];
    if (snapshot == nil or clock_seconds() - snapshot.time > 90) then
        -- The client does not expose enough information to reproduce Horizon's
        -- overload calculation. Stay neutral rather than inventing risk from
        -- active stacks or recent uses.
        return 'LOW', 0;
    end
    local score = snapshot.chance;
    if (score >= 50) then
        return 'DANGER', score;
    elseif (score >= 20) then
        return 'WARM', score;
    end
    return 'LOW', score;
end

local function transform_point(x, y, z, matrix)
    return
        matrix._11 * x + matrix._21 * y + matrix._31 * z + matrix._41,
        matrix._12 * x + matrix._22 * y + matrix._32 * z + matrix._42,
        matrix._13 * x + matrix._23 * y + matrix._33 * z + matrix._43,
        matrix._14 * x + matrix._24 * y + matrix._34 * z + matrix._44;
end

local function get_viewport()
    local device = d3d8.get_device();
    if (device == nil) then
        return nil;
    end
    local _, viewport = device:GetViewport();
    if (viewport == nil or viewport.Width <= 0 or viewport.Height <= 0) then
        return nil;
    end
    return device, viewport;
end

local function project_character()
    local device, viewport = get_viewport();
    if (device == nil) then
        return nil, nil, nil;
    end

    local party = AshitaCore:GetMemoryManager():GetParty();
    local entity = AshitaCore:GetMemoryManager():GetEntity();
    if (party == nil or entity == nil) then
        return nil, nil, viewport;
    end

    local index = party:GetMemberTargetIndex(0);
    if (index == nil or index == 0 or entity:GetRawEntity(index) == nil) then
        return nil, nil, viewport;
    end

    local world_x = entity:GetLocalPositionX(index);
    local world_y = entity:GetLocalPositionY(index);
    -- Project the model origin instead of a guessed head height. A fixed world
    -- height is race-dependent and can leave the camera frustum for Tarutaru.
    local world_z = entity:GetLocalPositionZ(index) + ORIGIN_WORLD_LIFT;
    if (not is_finite(world_x) or not is_finite(world_y) or not is_finite(world_z)) then
        return nil, nil, viewport;
    end

    local _, view = device:GetTransform(C.D3DTS_VIEW);
    local _, projection = device:GetTransform(C.D3DTS_PROJECTION);
    if (view == nil or projection == nil) then
        return nil, nil, viewport;
    end

    -- FFXI entity coordinates are X/Y(horizontal)/Z(vertical), while D3D uses
    -- X/Y(vertical)/Z(depth) for the view transform.
    local vx, vy, vz, vw = transform_point(world_x, world_z, world_y, view);
    local cx, cy, cz, cw = transform_point(vx, vy, vz, projection);
    if (not is_finite(cw) or cw <= 0.001) then
        return nil, nil, viewport;
    end

    local ndc_x = cx / cw;
    local ndc_y = cy / cw;
    local ndc_z = cz / cw;
    if (not is_finite(ndc_x) or not is_finite(ndc_y) or not is_finite(ndc_z)
        or ndc_z < 0 or ndc_z > 1) then
        return nil, nil, viewport;
    end

    local screen_x = viewport.X + ((ndc_x + 1) * 0.5 * viewport.Width);
    local screen_y = viewport.Y + ((1 - ndc_y) * 0.5 * viewport.Height);
    local outside_view = screen_x < viewport.X
        or screen_x > viewport.X + viewport.Width
        or screen_y < viewport.Y
        or screen_y > viewport.Y + viewport.Height;
    if (outside_view and not state.settings.safearea) then
        return nil, nil, viewport;
    end
    -- Combat cameras can crop the model origin while the character remains
    -- visible. Accept a modest overscan region, then clamp the drawn formation.
    local overscan_x = viewport.Width * 0.35;
    local overscan_y = viewport.Height * 0.35;
    if (screen_x < viewport.X - overscan_x
        or screen_x > viewport.X + viewport.Width + overscan_x
        or screen_y < viewport.Y - overscan_y
        or screen_y > viewport.Y + viewport.Height + overscan_y) then
        return nil, nil, viewport;
    end
    return screen_x, screen_y, viewport;
end

local function safe_anchor()
    local ok, x, y, viewport = pcall(project_character);
    if (ok and x ~= nil and y ~= nil) then
        return x, y, viewport;
    end

    if (not state.settings.fallback) then
        return nil, nil, viewport;
    end
    if (viewport == nil) then
        local viewport_ok, _, fallback_viewport = pcall(get_viewport);
        if (viewport_ok) then
            viewport = fallback_viewport;
        end
    end
    if (viewport == nil) then
        return nil, nil, nil;
    end
    return viewport.X + viewport.Width * 0.5,
        viewport.Y + viewport.Height * 0.58, viewport;
end

local function smooth_anchor(x, y, now)
    local smoothing = state.settings.smoothing;
    if (smoothing <= 0 or state.anchor_x == nil or state.anchor_y == nil
        or state.anchor_time <= 0) then
        state.anchor_x, state.anchor_y, state.anchor_time = x, y, now;
        return x, y;
    end

    local delta = now - state.anchor_time;
    local dx, dy = x - state.anchor_x, y - state.anchor_y;
    local distance = math.sqrt(dx * dx + dy * dy);
    if (delta <= 0 or delta > 0.25 or distance > 240) then
        state.anchor_x, state.anchor_y, state.anchor_time = x, y, now;
        return x, y;
    end

    local factor = 1 - math.exp(-delta / smoothing);
    state.anchor_x = state.anchor_x + dx * factor;
    state.anchor_y = state.anchor_y + dy * factor;
    state.anchor_time = now;
    return state.anchor_x, state.anchor_y;
end

local function smooth_engagement_offset(engaged, now)
    local target = engaged and 0 or 1;
    if (state.idle_blend == nil or state.engagement_time <= 0) then
        state.idle_blend = target;
        state.engagement_time = now;
        return target;
    end

    local delta = now - state.engagement_time;
    if (delta <= 0 or delta > 0.5) then
        state.idle_blend = target;
        state.engagement_time = now;
        return target;
    end

    local factor = 1 - math.exp(-delta / ENGAGEMENT_BLEND_SECONDS);
    state.idle_blend = state.idle_blend
        + (target - state.idle_blend) * factor;
    if (math.abs(target - state.idle_blend) < 0.001) then
        state.idle_blend = target;
    end
    state.engagement_time = now;
    return state.idle_blend;
end

local function smooth_deploy_focus(deployed, now)
    local target = state.settings.deploy_focus and deployed and 1 or 0;
    if (state.deploy_blend == nil or state.deploy_time <= 0) then
        state.deploy_blend = target;
        state.deploy_time = now;
        return target;
    end

    local delta = now - state.deploy_time;
    if (delta <= 0 or delta > 0.5) then
        state.deploy_blend = target;
        state.deploy_time = now;
        return target;
    end

    local factor = 1 - math.exp(-delta / DEPLOY_BLEND_SECONDS);
    state.deploy_blend = state.deploy_blend
        + (target - state.deploy_blend) * factor;
    if (math.abs(target - state.deploy_blend) < 0.001) then
        state.deploy_blend = target;
    end
    state.deploy_time = now;
    return state.deploy_blend;
end

local function with_alpha(color, alpha)
    return { color[1], color[2], color[3], clamp(alpha, 0, 1) };
end

local function display_color(element)
    if (state.settings.colorblind) then
        return colorblind_colors[element.name] or element.color;
    end
    return element.color;
end

local function draw_element_glyph(draw, name, x, y, size, color)
    local half = size * 0.5;
    local glyph = imgui.GetColorU32(color);

    if (name == 'Fire') then
        draw:AddTriangleFilled(
            { x, y - half }, { x - half * 0.78, y + half },
            { x + half * 0.78, y + half }, glyph);
    elseif (name == 'Ice') then
        draw:AddQuadFilled(
            { x, y - half }, { x + half, y },
            { x, y + half }, { x - half, y }, glyph);
    elseif (name == 'Wind') then
        draw:AddLine({ x - half, y - half * 0.38 }, { x + half, y - half * 0.38 }, glyph, 1.8);
        draw:AddLine({ x - half * 0.72, y }, { x + half, y }, glyph, 1.8);
        draw:AddLine({ x - half * 0.20, y + half * 0.40 }, { x + half * 0.72, y + half * 0.40 }, glyph, 1.8);
    elseif (name == 'Earth') then
        draw:AddRectFilled(
            { x - half * 0.78, y - half * 0.78 },
            { x + half * 0.78, y + half * 0.78 }, glyph, 1.2);
    elseif (name == 'Thunder') then
        draw:AddLine({ x + half * 0.22, y - half }, { x - half * 0.22, y }, glyph, 2.2);
        draw:AddLine({ x - half * 0.22, y }, { x + half * 0.27, y }, glyph, 2.2);
        draw:AddLine({ x + half * 0.27, y }, { x - half * 0.18, y + half }, glyph, 2.2);
    elseif (name == 'Water') then
        draw:AddTriangleFilled(
            { x, y - half }, { x - half * 0.72, y + half * 0.12 },
            { x + half * 0.72, y + half * 0.12 }, glyph);
        draw:AddCircleFilled({ x, y + half * 0.18 }, half * 0.68, glyph, 12);
    elseif (name == 'Light') then
        draw:AddCircleFilled({ x, y }, half * 0.50, glyph, 12);
        draw:AddLine({ x - half, y }, { x + half, y }, glyph, 1.4);
        draw:AddLine({ x, y - half }, { x, y + half }, glyph, 1.4);
    else -- Dark
        draw:AddCircle({ x, y }, half * 0.84, glyph, 16, 1.9);
        draw:AddLine(
            { x - half * 0.62, y + half * 0.62 },
            { x + half * 0.62, y - half * 0.62 }, glyph, 1.7);
    end
end

local function luminous_color(color, alpha)
    return {
        clamp(color[1] * 1.18 + 0.10, 0, 1),
        clamp(color[2] * 1.18 + 0.10, 0, 1),
        clamp(color[3] * 1.18 + 0.10, 0, 1),
        clamp(alpha, 0, 1),
    };
end

local function draw_arc(draw, x, y, radius, start_angle, end_angle, color, thickness, segments)
    if (draw.PathArcTo == nil) then
        return;
    end
    draw:PathClear();
    draw:PathArcTo({ x, y }, radius, start_angle, end_angle, segments or 8);
    draw:PathStroke(color, 0, thickness);
end

local function draw_radial_line(draw, x, y, inner, outer, angle, color, thickness)
    draw:AddLine(
        { x + math.cos(angle) * inner, y + math.sin(angle) * inner },
        { x + math.cos(angle) * outer, y + math.sin(angle) * outer },
        color, thickness);
end

local function draw_element_crest(draw, name, x, y, size, color, now, motion)
    local half = size * 0.5;
    local scale = state.settings.scale;
    local time = now or 0;
    local motion_strength = clamp(tonumber(motion) or 0, 0, 1);
    local bright = imgui.GetColorU32(color);
    local shadow = imgui.GetColorU32({ 0.002, 0.012, 0.020, color[4] * 0.96 });
    local dim = imgui.GetColorU32(with_alpha(color, color[4] * 0.42));

    local function crest_line(p1, p2, width)
        draw:AddLine(p1, p2, shadow, width + 2.2 * scale);
        draw:AddLine(p1, p2, bright, width);
    end

    local function crest_arc(arc_radius, start_angle, end_angle, width, segments)
        draw_arc(draw, x, y, arc_radius, start_angle, end_angle,
            shadow, width + 2.2 * scale, segments);
        draw_arc(draw, x, y, arc_radius, start_angle, end_angle,
            bright, width, segments);
    end

    local line = math.max(1.15, 1.55 * scale);
    if (name == 'Fire') then
        -- A three-pronged flame converging into a single ember point.
        local center_flicker = math.sin(time * 4.1) * half * 0.055 * motion_strength;
        local left_flicker = math.sin(time * 3.4 + 1.8) * half * 0.06 * motion_strength;
        local right_flicker = math.sin(time * 3.8 + 4.0) * half * 0.06 * motion_strength;
        crest_line(
            { x, y + half * 0.84 },
            { x, y - half * 0.92 + center_flicker }, line * 1.18);
        crest_line(
            { x, y + half * 0.68 }, { x - half * 0.62, y + half * 0.05 }, line);
        crest_line(
            { x - half * 0.62, y + half * 0.05 },
            { x - half * 0.44, y - half * 0.66 + left_flicker }, line);
        crest_line(
            { x, y + half * 0.68 }, { x + half * 0.62, y + half * 0.05 }, line);
        crest_line(
            { x + half * 0.62, y + half * 0.05 },
            { x + half * 0.44, y - half * 0.66 + right_flicker }, line);
        draw:AddCircleFilled({ x, y + half * 0.72 }, half * 0.12, bright, 8);
    elseif (name == 'Ice') then
        -- Six-point snow crystal with small split tips.
        for axis = 0, 2 do
            local angle = axis * math.pi / 3;
            crest_line(
                { x - math.cos(angle) * half * 0.88,
                  y - math.sin(angle) * half * 0.88 },
                { x + math.cos(angle) * half * 0.88,
                  y + math.sin(angle) * half * 0.88 }, line);
            for direction = -1, 1, 2 do
                local end_angle = angle + (direction < 0 and math.pi or 0);
                local bx = x + math.cos(end_angle) * half * 0.53;
                local by = y + math.sin(end_angle) * half * 0.53;
                for fork = -1, 1, 2 do
                    local fork_angle = end_angle + fork * 0.48;
                    crest_line(
                        { bx, by },
                        { x + math.cos(fork_angle) * half * 0.79,
                          y + math.sin(fork_angle) * half * 0.79 },
                        line * 0.72);
                end
            end
        end
        if (motion_strength > 0) then
            local sparkle_angle = math.floor(time * 1.6) % 6 * TAU / 6;
            local sparkle_pulse = 0.5 + 0.5 * math.sin(time * 5.0);
            draw:AddCircleFilled(
                { x + math.cos(sparkle_angle) * half * 0.90,
                  y + math.sin(sparkle_angle) * half * 0.90 },
                half * (0.045 + sparkle_pulse * 0.045) * motion_strength,
                bright, 8);
        end
    elseif (name == 'Wind') then
        -- Three nested gusts form a readable spiral instead of parallel bars.
        local spin = time * 0.12 * motion_strength;
        crest_arc(half * 0.78, -2.65 + spin, -0.08 + spin, line, 10);
        crest_arc(half * 0.53, -2.18 + spin, 0.47 + spin, line, 9);
        crest_arc(half * 0.29, -1.56 + spin, 0.82 + spin, line, 7);
        draw:AddCircleFilled(
            { x + math.cos(-0.12 + spin) * half * 0.69,
              y + math.sin(-0.12 + spin) * half * 0.69 },
            half * 0.10, bright, 8);
    elseif (name == 'Earth') then
        -- A faceted mountain-cut crystal with a strong grounded baseline.
        local settle = math.sin(time * 0.85) * half * 0.018 * motion_strength;
        local top = { x, y - half * 0.86 + settle };
        local left = { x - half * 0.82, y + half * 0.62 };
        local right = { x + half * 0.82, y + half * 0.62 };
        local center = { x, y + half * 0.18 - settle };
        crest_line(top, left, line * 1.12);
        crest_line(top, right, line * 1.12);
        crest_line(left, right, line * 1.18);
        crest_line(top, center, line * 0.82);
        crest_line(center, left, line * 0.82);
        crest_line(center, right, line * 0.82);
        draw:AddLine(
            { x - half * 0.52, y + half * 0.78 },
            { x + half * 0.52, y + half * 0.78 }, dim, line * 0.72);
    elseif (name == 'Thunder') then
        -- Heavy primary bolt with a smaller fork at the center break.
        local jolt = (math.sin(time * 8.5) + math.sin(time * 13.1 + 1.7))
            * half * 0.022 * motion_strength;
        local p1 = { x + half * 0.30, y - half * 0.92 };
        local p2 = { x - half * 0.30 + jolt, y - half * 0.04 };
        local p3 = { x + half * 0.12 - jolt, y - half * 0.04 };
        local p4 = { x - half * 0.36, y + half * 0.92 };
        crest_line(p1, p2, line * 1.28);
        crest_line(p2, p3, line * 1.28);
        crest_line(p3, p4, line * 1.28);
        crest_line(p2, { x - half * 0.70, y + half * 0.36 }, line * 0.82);
        crest_line(p3, { x + half * 0.64, y + half * 0.29 }, line * 0.82);
    elseif (name == 'Water') then
        -- A pointed droplet containing one clean rolling wave.
        local tip = { x, y - half * 0.92 };
        local left = { x - half * 0.61, y };
        local right = { x + half * 0.61, y };
        crest_line(tip, left, line);
        crest_line(tip, right, line);
        crest_arc(half * 0.61, 0, math.pi, line, 10);
        local wave_y = y + half * (0.19
            + math.sin(time * 1.25) * 0.05 * motion_strength);
        draw_arc(draw, x, wave_y, half * 0.38,
            math.pi * 1.06, math.pi * 1.92, shadow, line + 1.8 * scale, 7);
        draw_arc(draw, x, wave_y, half * 0.38,
            math.pi * 1.06, math.pi * 1.92, bright, line * 0.82, 7);
    elseif (name == 'Light') then
        -- Eight-ray star surrounding a solid diamond core.
        local ray_breathe = 1 + math.sin(time * 1.1)
            * 0.06 * motion_strength;
        for ray = 0, 7 do
            local angle = ray * TAU / 8;
            draw_radial_line(draw, x, y, half * 0.48, half * 0.91 * ray_breathe,
                angle, shadow, line + 2.0 * scale);
            draw_radial_line(draw, x, y, half * 0.48, half * 0.91 * ray_breathe,
                angle, bright, ray % 2 == 0 and line or line * 0.74);
        end
        draw:AddQuadFilled(
            { x, y - half * 0.48 }, { x + half * 0.48, y },
            { x, y + half * 0.48 }, { x - half * 0.48, y }, shadow);
        draw:AddQuadFilled(
            { x, y - half * 0.34 }, { x + half * 0.34, y },
            { x, y + half * 0.34 }, { x - half * 0.34, y }, bright);
    else -- Dark
        -- An eclipsed crescent with three small void stars.
        local eclipse_shift = math.sin(time * 0.70)
            * half * 0.06 * motion_strength;
        draw:AddCircleFilled({ x - half * 0.08, y }, half * 0.73, shadow, 20);
        draw:AddCircleFilled({ x - half * 0.08, y }, half * 0.62, bright, 20);
        draw:AddCircleFilled(
            { x + half * 0.25 + eclipse_shift, y - half * 0.16 }, half * 0.55,
            imgui.GetColorU32({ 0.008, 0.025, 0.040, color[4] }), 18);
        for star = 0, 2 do
            local angle = -0.82 + star * 0.72
                + time * 0.08 * motion_strength;
            draw:AddCircleFilled(
                { x + math.cos(angle) * half * 0.69,
                  y + math.sin(angle) * half * 0.69 },
                half * (star == 1 and 0.10 or 0.07), bright, 6);
        end
    end
end

local function draw_mechanical_frame(draw, element, x, y, radius, color, alpha, now)
    local scale = state.settings.scale;
    local plate_radius = radius * 0.78;
    local points = {};
    for index = 0, 5 do
        local angle = -math.pi * 0.5 + index * TAU / 6;
        points[index + 1] = {
            x + math.cos(angle) * plate_radius,
            y + math.sin(angle) * plate_radius,
        };
    end

    local plate_a = imgui.GetColorU32({ 0.018, 0.035, 0.043, alpha * 0.96 });
    local plate_b = imgui.GetColorU32({ 0.034, 0.059, 0.067, alpha * 0.96 });
    local shadow = imgui.GetColorU32({ 0.002, 0.008, 0.012, alpha * 0.92 });
    local brass = imgui.GetColorU32({ 0.82, 0.62, 0.29, alpha * 0.88 });
    local dim_brass = imgui.GetColorU32({ 0.58, 0.42, 0.20, alpha * 0.54 });
    local element_edge = imgui.GetColorU32(with_alpha(color, alpha * 0.46));

    -- Alternating gunmetal facets give the plate depth without tiny textures.
    for index = 1, 6 do
        draw:AddTriangleFilled(
            { x, y }, points[index], points[index % 6 + 1],
            index % 2 == 0 and plate_a or plate_b);
    end
    for index = 1, 6 do
        local next_point = points[index % 6 + 1];
        draw:AddLine(points[index], next_point, shadow,
            math.max(1.0, 3.1 * scale));
        draw:AddLine(points[index], next_point,
            index % 2 == 0 and brass or dim_brass,
            math.max(1.0, 1.25 * scale));
    end

    -- Three gear teeth rotate slowly around the fixed automaton plate.
    local phase = now * 0.16 + element.ability * 0.29;
    for tooth = 0, 2 do
        local angle = phase + tooth * TAU / 3;
        local cosine, sine = math.cos(angle), math.sin(angle);
        local tangent_x, tangent_y = -sine, cosine;
        local inner = radius * 0.73;
        local outer = radius * 0.98;
        local inner_width = radius * 0.13;
        local outer_width = radius * 0.09;
        local p1 = {
            x + cosine * inner + tangent_x * inner_width,
            y + sine * inner + tangent_y * inner_width,
        };
        local p2 = {
            x + cosine * outer + tangent_x * outer_width,
            y + sine * outer + tangent_y * outer_width,
        };
        local p3 = {
            x + cosine * outer - tangent_x * outer_width,
            y + sine * outer - tangent_y * outer_width,
        };
        local p4 = {
            x + cosine * inner - tangent_x * inner_width,
            y + sine * inner - tangent_y * inner_width,
        };
        draw:AddQuadFilled(p1, p2, p3, p4, plate_b);
        draw:AddLine(p1, p2, brass, math.max(1.0, 1.05 * scale));
        draw:AddLine(p2, p3, brass, math.max(1.0, 1.05 * scale));
        draw:AddLine(p3, p4, dim_brass, math.max(1.0, 1.05 * scale));
        draw:AddCircleFilled(
            { x + cosine * radius * 0.72, y + sine * radius * 0.72 },
            math.max(0.8, radius * 0.065), brass, 8);
    end

    -- A segmented inner bearing turns in the opposite direction.
    for segment = 0, 5 do
        local start_angle = -phase * 0.72 + segment * TAU / 6;
        draw_arc(draw, x, y, radius * 0.57, start_angle,
            start_angle + 0.54, segment % 2 == 0 and element_edge or dim_brass,
            math.max(1.0, 1.0 * scale), 5);
    end

    -- One cool highlight keeps the metal readable without restoring glassiness.
    draw:AddLine(
        { x - plate_radius * 0.42, y - plate_radius * 0.62 },
        { x + plate_radius * 0.15, y - plate_radius * 0.78 },
        imgui.GetColorU32({ 0.88, 0.94, 0.95, alpha * 0.24 }),
        math.max(1.0, 0.9 * scale));
end

local function draw_element_flourish(draw, element, x, y, radius, color, alpha, now)
    if (not state.settings.effects) then
        return;
    end

    local phase = now * 0.42 + element.ability * 0.71;
    local bright = imgui.GetColorU32(luminous_color(color, alpha * 0.52));
    local dim = imgui.GetColorU32(with_alpha(color, alpha * 0.32));
    local fine = math.max(1.0, state.settings.scale);

    if (element.name == 'Fire') then
        -- Three slowly circling embers with short heat trails.
        for index = 0, 2 do
            local angle = phase + index * TAU / 3;
            draw_radial_line(draw, x, y, radius * 0.56, radius * 0.78, angle, dim, fine);
            draw:AddCircleFilled(
                { x + math.cos(angle) * radius * 0.78,
                  y + math.sin(angle) * radius * 0.78 },
                radius * (0.065 + index * 0.012), bright, 8);
        end
    elseif (element.name == 'Ice') then
        -- A crystalline four-point lattice rotates almost imperceptibly.
        for index = 0, 3 do
            local angle = phase * 0.18 + index * math.pi / 2;
            draw_radial_line(draw, x, y, radius * 0.42, radius * 0.82, angle, bright, fine);
            draw_radial_line(draw, x, y, radius * 0.62, radius * 0.76,
                angle + math.pi * 0.20, dim, fine);
            draw_radial_line(draw, x, y, radius * 0.62, radius * 0.76,
                angle - math.pi * 0.20, dim, fine);
        end
    elseif (element.name == 'Wind') then
        -- Counter-rotating air currents.
        draw_arc(draw, x, y, radius * 0.76, phase, phase + 1.45, bright, fine, 8);
        draw_arc(draw, x, y, radius * 0.54, -phase * 0.72,
            -phase * 0.72 + 1.30, dim, fine, 7);
    elseif (element.name == 'Earth') then
        -- Four steady stone studs give the orb a weightier silhouette.
        for index = 0, 3 do
            local angle = math.pi * 0.25 + index * math.pi / 2;
            local px = x + math.cos(angle) * radius * 0.63;
            local py = y + math.sin(angle) * radius * 0.63;
            local size = radius * 0.10;
            draw:AddRectFilled(
                { px - size, py - size }, { px + size, py + size },
                index % 2 == 0 and bright or dim, 1.0);
        end
    elseif (element.name == 'Thunder') then
        -- Small electrical forks chase around the inner rim.
        for index = 0, 2 do
            local angle = -phase * 1.15 + index * TAU / 3;
            local a1 = angle - 0.13;
            local a2 = angle + 0.10;
            draw:AddLine(
                { x + math.cos(a1) * radius * 0.48, y + math.sin(a1) * radius * 0.48 },
                { x + math.cos(angle) * radius * 0.73, y + math.sin(angle) * radius * 0.73 },
                bright, fine * 1.15);
            draw:AddLine(
                { x + math.cos(angle) * radius * 0.73, y + math.sin(angle) * radius * 0.73 },
                { x + math.cos(a2) * radius * 0.84, y + math.sin(a2) * radius * 0.84 },
                dim, fine * 1.15);
        end
    elseif (element.name == 'Water') then
        -- Bubbles rise through a slowly turning current.
        for index = 0, 2 do
            local angle = phase * 0.64 + index * TAU / 3;
            local distance = radius * (0.48 + index * 0.10);
            draw:AddCircle(
                { x + math.cos(angle) * distance,
                  y + math.sin(angle) * distance },
                radius * (0.065 + index * 0.025),
                index == 2 and bright or dim, 10, fine);
        end
    elseif (element.name == 'Light') then
        -- A restrained rotating sunburst.
        for index = 0, 7 do
            local angle = phase * 0.16 + index * TAU / 8;
            local outer = index % 2 == 0 and radius * 0.84 or radius * 0.76;
            draw_radial_line(draw, x, y, radius * 0.56, outer, angle,
                index % 2 == 0 and bright or dim, fine);
        end
    else -- Dark
        -- Broken orbital arcs and two dim satellites.
        draw_arc(draw, x, y, radius * 0.72, phase, phase + 1.35, bright, fine, 8);
        draw_arc(draw, x, y, radius * 0.72, phase + math.pi,
            phase + math.pi + 0.92, dim, fine, 6);
        for index = 0, 1 do
            local angle = -phase * 0.58 + index * math.pi;
            draw:AddCircleFilled(
                { x + math.cos(angle) * radius * 0.73,
                  y + math.sin(angle) * radius * 0.73 },
                radius * 0.075, index == 0 and bright or dim, 8);
        end
    end
end

local function draw_element_shell(draw, element, x, y, radius, color, alpha, now)
    local bright = imgui.GetColorU32(luminous_color(color, alpha * 0.58));
    local dim = imgui.GetColorU32(with_alpha(color, alpha * 0.24));
    local line = math.max(1.0, state.settings.scale * 1.15);
    local phase = now * 0.18 + element.ability * 0.37;

    if (element.name == 'Fire') then
        -- Three flame fins break the circular silhouette.
        for index = 0, 2 do
            local angle = -math.pi * 0.5 + (index - 1) * 0.72;
            local tangent_x = -math.sin(angle) * radius * 0.20;
            local tangent_y = math.cos(angle) * radius * 0.20;
            local base_x = x + math.cos(angle) * radius * 0.88;
            local base_y = y + math.sin(angle) * radius * 0.88;
            draw:AddTriangleFilled(
                { base_x - tangent_x, base_y - tangent_y },
                { x + math.cos(angle) * radius * (1.22 + index * 0.05),
                  y + math.sin(angle) * radius * (1.22 + index * 0.05) },
                { base_x + tangent_x, base_y + tangent_y },
                index == 1 and bright or dim);
        end
    elseif (element.name == 'Ice') then
        -- A faceted crystal cage with alternating long and short vertices.
        local points = {};
        for index = 0, 7 do
            local angle = -math.pi * 0.5 + index * TAU / 8;
            local length = index % 2 == 0 and radius * 1.20 or radius * 1.02;
            points[index + 1] = {
                x + math.cos(angle) * length,
                y + math.sin(angle) * length,
            };
        end
        for index = 1, 8 do
            draw:AddLine(points[index], points[index % 8 + 1],
                index % 2 == 0 and bright or dim, line);
        end
    elseif (element.name == 'Wind') then
        -- Three separated bands imply a shell made from moving air.
        for index = 0, 2 do
            local start_angle = phase + index * TAU / 3;
            draw_arc(draw, x, y, radius * (1.04 + index * 0.045),
                start_angle, start_angle + 1.05,
                index == 1 and bright or dim, line, 7);
        end
    elseif (element.name == 'Earth') then
        -- A heavy octagonal casing with cardinal anchor plates.
        local points = {};
        for index = 0, 7 do
            local angle = math.pi * 0.125 + index * TAU / 8;
            points[index + 1] = {
                x + math.cos(angle) * radius * 1.08,
                y + math.sin(angle) * radius * 1.08,
            };
        end
        for index = 1, 8 do
            draw:AddLine(points[index], points[index % 8 + 1],
                index % 2 == 0 and bright or dim, line * 1.35);
        end
        for index = 0, 3 do
            local angle = index * math.pi / 2;
            local px = x + math.cos(angle) * radius * 1.10;
            local py = y + math.sin(angle) * radius * 1.10;
            local size = radius * 0.085;
            draw:AddRectFilled({ px - size, py - size }, { px + size, py + size },
                bright, 1.0);
        end
    elseif (element.name == 'Thunder') then
        -- An irregular alternating-radius ring reads as contained lightning.
        local previous_x, previous_y = nil, nil;
        for index = 0, 12 do
            local wrapped = index % 12;
            local angle = phase * 1.8 + wrapped * TAU / 12;
            local length = wrapped % 2 == 0 and radius * 1.18 or radius * 0.99;
            local px = x + math.cos(angle) * length;
            local py = y + math.sin(angle) * length;
            if (index > 0) then
                draw:AddLine({ previous_x, previous_y }, { px, py },
                    wrapped % 3 == 0 and bright or dim, line);
            end
            previous_x, previous_y = px, py;
        end
    elseif (element.name == 'Water') then
        -- A droplet crown plus two surface bubbles.
        draw:AddTriangleFilled(
            { x, y - radius * 1.34 },
            { x - radius * 0.34, y - radius * 0.72 },
            { x + radius * 0.34, y - radius * 0.72 }, dim);
        for index = 0, 1 do
            local angle = phase + index * 2.4;
            draw:AddCircle(
                { x + math.cos(angle) * radius * 1.04,
                  y + math.sin(angle) * radius * 1.04 },
                radius * (0.09 + index * 0.035),
                index == 0 and bright or dim, 10, line);
        end
    elseif (element.name == 'Light') then
        -- Alternating long and short rays form a clean sun shell.
        for index = 0, 7 do
            local angle = phase * 0.28 + index * TAU / 8;
            local outer = index % 2 == 0 and radius * 1.30 or radius * 1.18;
            draw_radial_line(draw, x, y, radius * 0.98, outer, angle,
                index % 2 == 0 and bright or dim, line);
        end
    else -- Dark
        -- An eclipsed shell: two broken crescents with orbiting void motes.
        draw_arc(draw, x, y, radius * 1.10, phase, phase + 2.15,
            bright, line * 1.2, 12);
        draw_arc(draw, x, y, radius * 1.02, phase + math.pi,
            phase + math.pi + 1.45, dim, line, 9);
        for index = 0, 1 do
            local angle = -phase * 0.72 + index * math.pi;
            draw:AddCircleFilled(
                { x + math.cos(angle) * radius * 1.15,
                  y + math.sin(angle) * radius * 1.15 },
                radius * 0.07, index == 0 and bright or dim, 8);
        end
    end
end

local function draw_timer_ring(draw, x, y, radius, remaining, approximate, base_color, alpha, now)
    if (not state.settings.timers) then
        return;
    end

    local fraction = clamp(remaining / MANEUVER_DURATION, 0, 1);
    local ring_color = base_color;
    local thickness = math.max(1.3, state.settings.scale * 1.7);
    local ring_radius = radius + 4.5 * state.settings.scale;
    if (remaining <= 5) then
        local pulse = 0.5 + 0.5 * math.sin(now * TAU * 2.0);
        ring_color = { 1.00, 0.34, 0.10, 1.00 };
        ring_radius = ring_radius + pulse * 1.8 * state.settings.scale;
        thickness = thickness + pulse * 0.9;
    elseif (remaining <= 15) then
        ring_color = { 0.78, 0.63, 0.36, 1.00 };
    end

    local segments = 16;
    local step = TAU / segments;
    local active_segments = math.ceil(segments * fraction);
    local background_u32 = imgui.GetColorU32({ 0.02, 0.05, 0.07, alpha * 0.68 });
    local color_u32 = imgui.GetColorU32(with_alpha(ring_color, alpha));
    for segment = 0, segments - 1 do
        local a1 = -math.pi * 0.5 + segment * step + step * 0.10;
        local a2 = -math.pi * 0.5 + (segment + 1) * step - step * 0.20;
        local p1 = { x + math.cos(a1) * ring_radius, y + math.sin(a1) * ring_radius };
        local p2 = { x + math.cos(a2) * ring_radius, y + math.sin(a2) * ring_radius };
        draw:AddLine(p1, p2, background_u32, thickness);

        local active = segment < active_segments;
        local visible = active and (not approximate or segment % 2 == 0);
        if (visible) then
            draw:AddLine(p1, p2, color_u32,
                approximate and thickness * 0.82 or thickness);

            -- Cardinal segments receive a tiny outward rune tick.
            if (segment % 4 == 0) then
                local middle = (a1 + a2) * 0.5;
                draw:AddLine(
                    { x + math.cos(middle) * (ring_radius - 1.0 * state.settings.scale),
                      y + math.sin(middle) * (ring_radius - 1.0 * state.settings.scale) },
                    { x + math.cos(middle) * (ring_radius + 2.0 * state.settings.scale),
                      y + math.sin(middle) * (ring_radius + 2.0 * state.settings.scale) },
                    color_u32, thickness * 0.72);
            end
        end
    end
end

local function draw_shared_recast_mote(draw, items, now)
    if (not state.settings.recast_ring or #items == 0) then
        return;
    end

    local active = {};
    for _, item in ipairs(items) do
        if (item.slot ~= nil and not item.departing) then
            table.insert(active, item);
        end
    end
    if (#active == 0) then
        return;
    end

    local center_x, center_y = 0, 0;
    local formation_alpha = 1;
    local orbit_blend = 0;
    for _, item in ipairs(active) do
        center_x = center_x + item.x;
        center_y = center_y + item.y;
        formation_alpha = math.min(formation_alpha, item.alpha or 1);
        orbit_blend = orbit_blend + (item.orbit_blend or 0);
    end
    center_x = center_x / #active;
    center_y = center_y / #active;
    orbit_blend = clamp(orbit_blend / #active, 0, 1);

    local radius = 0;
    for _, item in ipairs(active) do
        local dx, dy = item.x - center_x, item.y - center_y;
        radius = math.max(radius, math.sqrt(dx * dx + dy * dy));
    end
    radius = radius + 29 * state.settings.scale;

    local remaining = maneuver_recast();
    local active_recast = remaining > 0.001;
    if (active_recast) then
        state.recast_was_active = true;
    elseif (state.recast_was_active) then
        state.recast_was_active = false;
        state.recast_ready_at = now;
    end

    local progress = clamp(1 - remaining / MANEUVER_RECAST_SECONDS, 0, 1);
    local start_angle = -math.pi * 0.5;
    if (active_recast) then
        local angle = start_angle + TAU * progress;
        local trail_length = 0.105 * TAU;
        local trail_steps = 7;
        local available_trail = math.min(trail_length, TAU * progress);
        if (available_trail > 0.002) then
            for step = trail_steps, 1, -1 do
                local trail_progress = step / trail_steps;
                local trail_angle = angle - available_trail * trail_progress;
                local trail_alpha = formation_alpha
                    * 0.34 * (1 - trail_progress) * (1 - trail_progress)
                    * (1 - orbit_blend);
                local trail_size = (0.7 + (1 - trail_progress) * 0.75)
                    * state.settings.scale;
                draw:AddCircleFilled({
                    center_x + math.cos(trail_angle) * radius,
                    center_y + math.sin(trail_angle) * radius,
                }, math.max(0.65, trail_size),
                    imgui.GetColorU32({ 0.88, 0.68, 0.31, trail_alpha }), 8);
            end
        end

        -- As the formation becomes a carousel, ease the recast mote to twelve
        -- o'clock and replace its competing large orbit with a local gauge.
        local pin_delta = ((start_angle - angle + math.pi) % TAU) - math.pi;
        local display_angle = angle + pin_delta * orbit_blend;
        local mote_x = center_x + math.cos(display_angle) * radius;
        local mote_y = center_y + math.sin(display_angle) * radius;
        if (orbit_blend > 0.01) then
            local gauge_radius = 6.0 * state.settings.scale;
            local gauge_alpha = formation_alpha * orbit_blend;
            draw:AddCircle({ mote_x, mote_y }, gauge_radius,
                imgui.GetColorU32({ 0.04, 0.07, 0.08, gauge_alpha * 0.78 }),
                20, math.max(1.0, 2.2 * state.settings.scale));
            if (progress > 0.002) then
                draw_arc(draw, mote_x, mote_y, gauge_radius,
                    start_angle, start_angle + TAU * progress,
                    imgui.GetColorU32({ 0.96, 0.76, 0.32, gauge_alpha }),
                    math.max(1.0, 1.55 * state.settings.scale), 20);
            end
        end
        draw:AddCircleFilled({ mote_x, mote_y }, 5.0 * state.settings.scale,
            imgui.GetColorU32({ 0.88, 0.68, 0.31,
                formation_alpha * 0.10 }), 12);
        draw:AddCircleFilled({ mote_x, mote_y }, 2.25 * state.settings.scale,
            imgui.GetColorU32({ 0.96, 0.80, 0.43,
                formation_alpha * 0.92 }), 10);
        draw:AddCircleFilled({ mote_x, mote_y }, 0.85 * state.settings.scale,
            imgui.GetColorU32({ 1.00, 0.96, 0.78,
                formation_alpha }), 8);
        return;
    end

    local age = now - state.recast_ready_at;
    if (age < 0 or age >= 0.72) then
        return;
    end

    local burst_progress = age / 0.72;
    local ready_x = center_x;
    local ready_y = center_y - radius;
    local ready_alpha = formation_alpha * (1 - burst_progress);
    draw:AddCircleFilled({ ready_x, ready_y },
        (4.6 - burst_progress * 1.8) * state.settings.scale,
        imgui.GetColorU32({ 0.64, 1.00, 0.88, ready_alpha * 0.25 }), 12);
    draw:AddCircle({ ready_x, ready_y },
        (3.0 + burst_progress * 7.5) * state.settings.scale,
        imgui.GetColorU32({ 0.28, 0.90, 0.75, ready_alpha }), 24,
        math.max(1.0, (1.7 - burst_progress * 0.7) * state.settings.scale));
    draw:AddCircleFilled({ ready_x, ready_y },
        math.max(0.7, (2.0 - burst_progress * 1.2) * state.settings.scale),
        imgui.GetColorU32({ 0.88, 1.00, 0.95, ready_alpha }), 10);
end

local function draw_burden_halo(draw, item, radius, now)
    if (not state.settings.burden or item.risk == nil or item.risk == 'LOW') then
        return;
    end

    local danger = item.risk == 'DANGER';
    local overloaded = item.risk == 'OVERLOAD';
    local pulse_rate = overloaded and 8.0 or danger and 4.4 or 2.4;
    local pulse = 0.5 + 0.5 * math.sin(now * pulse_rate);
    local color = item.risk == 'WARM' and { 0.96, 0.72, 0.25, 1.00 }
        or danger and { 1.00, 0.40, 0.08, 1.00 }
        or { 1.00, 0.16, 0.10, 1.00 };
    local base_alpha = overloaded and 0.72 or danger and 0.62 or 0.50;
    local pulse_alpha = overloaded and 0.22 or danger and 0.16 or 0.10;
    local alpha = item.alpha * (base_alpha + pulse * pulse_alpha);
    local expansion = overloaded and 2.4 or danger and 1.5 or 0.8;
    local halo = radius + (10.0 + pulse * expansion) * state.settings.scale;
    local color_u32 = imgui.GetColorU32(with_alpha(color, alpha));
    local phase = now * (overloaded and 1.8 or danger and 0.85 or 0.42);
    local fragments = overloaded and 5 or 4;
    local span = overloaded and 0.48 or danger and 0.92 or 1.08;
    local thickness = state.settings.scale
        * (overloaded and (2.5 + pulse * 0.9)
            or danger and (2.2 + pulse * 0.6)
            or (1.9 + pulse * 0.35));

    -- A dim complete rail makes even warm risk readable behind bright elements.
    draw:AddCircle(
        { item.x, item.y }, halo,
        imgui.GetColorU32(with_alpha(color, item.alpha * (danger and 0.20 or 0.15))),
        32, math.max(1.0, thickness + 1.8 * state.settings.scale));

    for index = 0, fragments - 1 do
        local start_angle = phase + index * TAU / fragments;
        draw_arc(draw, item.x, item.y, halo, start_angle,
            start_angle + span, color_u32, math.max(1.0, thickness), 8);

        -- Bright outward ticks keep the warning distinct from the timer ring.
        local marker_angle = start_angle + span * 0.5;
        draw_radial_line(
            draw, item.x, item.y,
            halo - 1.0 * state.settings.scale,
            halo + (overloaded and 4.5 or danger and 3.8 or 3.2) * state.settings.scale,
            marker_angle, color_u32, math.max(1.0, thickness * 0.78));
    end
end

local function draw_activation_ripple(draw, item, element, radius, now)
    if (not state.settings.effects or not state.settings.transitions
        or item.slot.approximate or item.departing) then
        return;
    end
    local age = now - item.slot.started;
    if (age < 0 or age > 0.48) then
        return;
    end
    local progress = age / 0.48;
    draw:AddCircle(
        { item.x, item.y }, radius + progress * 14 * state.settings.scale,
        imgui.GetColorU32(luminous_color(
            display_color(element), item.alpha * (1 - progress) * 0.58)),
        28, math.max(1.0, (1.8 - progress) * state.settings.scale));
end

local function draw_confirmation_flash(draw, items, now)
    local flash = state.confirmation_flash;
    if (not state.settings.confirmation_flash or flash == nil) then
        state.confirmation_flash = nil;
        return;
    end

    local age = now - flash.started;
    local duration = 0.52;
    if (age < 0 or age > duration) then
        state.confirmation_flash = nil;
        return;
    end

    local item = nil;
    for _, candidate in ipairs(items) do
        if (candidate.slot == flash.slot and not candidate.departing) then
            item = candidate;
            break;
        end
    end
    if (item == nil) then
        return;
    end

    local element = elements[item.slot.ability];
    if (element == nil) then
        return;
    end
    local progress = age / duration;
    local fade = 1 - progress;
    local radius = (16.0 + progress * 11.0)
        * state.settings.scale * item.depth_scale;
    local color = display_color(element);
    local elemental = imgui.GetColorU32(luminous_color(
        color, item.alpha * fade * 0.88));
    local white = imgui.GetColorU32({ 0.95, 1.00, 1.00,
        item.alpha * fade * 0.72 });

    draw:AddCircle({ item.x, item.y }, radius, elemental, 30,
        math.max(1.0, (2.2 - progress * 0.9) * state.settings.scale));
    draw:AddCircleFilled({ item.x, item.y },
        (5.0 - progress * 2.4) * state.settings.scale,
        imgui.GetColorU32({ 0.95, 1.00, 1.00,
            item.alpha * fade * 0.13 }), 14);
    for index = 0, 3 do
        local angle = index * TAU / 4;
        draw_radial_line(draw, item.x, item.y,
            radius + 2.0 * state.settings.scale,
            radius + (6.0 - progress * 2.0) * state.settings.scale,
            angle, white, math.max(1.0, 1.4 * state.settings.scale));
    end
end

local function draw_overload_flash(draw, anchor_x, anchor_y, now)
    local flash = state.overload_flash;
    if (flash == nil) then
        return;
    end
    local age = now - flash.started;
    if (age < 0 or age > 0.60) then
        state.overload_flash = nil;
        return;
    end

    local progress = age / 0.60;
    local radius = (18 + progress * 18) * state.settings.scale;
    local alpha = (1 - progress) * 0.72;
    local color = imgui.GetColorU32({ 1.00, 0.22, 0.10, alpha });
    local center_y = anchor_y - state.settings.height * state.settings.scale * 0.64;
    for index = 0, 4 do
        local start_angle = index * TAU / 5 + progress * 0.45;
        draw_arc(draw, anchor_x, center_y, radius, start_angle,
            start_angle + 0.48, color,
            math.max(1.0, state.settings.scale * (2.0 - progress)), 6);
    end
end

local function draw_orb(draw, item, now)
    local element = elements[item.slot.ability];
    if (element == nil) then
        return;
    end

    local alpha = item.alpha;
    local radius = 13 * state.settings.scale * item.depth_scale;
    local color = display_color(element);
    local remaining = math.max(0, item.slot.expires - now);

    local aura_pulse = 1 + math.sin(now * 1.7 + element.ability) * 0.035;
    local resonating = (item.resonance_count or 1) > 1;
    local mechanical = state.settings.icon_mode == 'mechanical';
    local rim_width = math.max(1.0,
        (resonating and 1.48 or 1.25) * state.settings.scale);

    draw_burden_halo(draw, item, radius, now);
    draw_activation_ripple(draw, item, element, radius, now);

    -- Layered faux-radial lighting: aura, shadow plate, colored glass, and core.
    draw:AddCircleFilled(
        { item.x, item.y }, (radius + 7 * state.settings.scale) * aura_pulse,
        imgui.GetColorU32(with_alpha(color,
            alpha * (resonating and 0.115 or 0.075))), 28);
    draw_element_shell(draw, element, item.x, item.y, radius, color, alpha, now);
    draw:AddCircleFilled(
        { item.x, item.y + radius * 0.08 }, radius + 2.5 * state.settings.scale,
        imgui.GetColorU32({ 0.008, 0.025, 0.040, alpha * 0.92 }), 28);
    draw:AddCircleFilled(
        { item.x, item.y }, radius,
        imgui.GetColorU32(with_alpha(color, alpha * 0.26)), 28);
    draw:AddCircleFilled(
        { item.x, item.y }, radius * 0.78,
        imgui.GetColorU32({ 0.018, 0.065, 0.080, alpha * 0.84 }), 24);
    draw:AddCircleFilled(
        { item.x, item.y }, radius * 0.61,
        imgui.GetColorU32(with_alpha(color, alpha * 0.20)), 20);

    draw:AddCircle(
        { item.x, item.y }, radius + 1.2 * state.settings.scale,
        imgui.GetColorU32(with_alpha(color, alpha * 0.78)), 28, rim_width);
    if (mechanical) then
        -- Keep the elemental motion behind the opaque automaton plate.
        draw_element_flourish(
            draw, element, item.x, item.y, radius, color, alpha, now);
        draw_mechanical_frame(
            draw, element, item.x, item.y, radius, color, alpha, now);
    else
        draw:AddCircle(
            { item.x, item.y }, radius * 0.79,
            imgui.GetColorU32(luminous_color(color, alpha * 0.34)),
            24, rim_width * 0.72);
        draw_element_flourish(
            draw, element, item.x, item.y, radius, color, alpha, now);

        -- A small upper-left glint gives the primitive orb a glassy face.
        draw:AddCircleFilled(
            { item.x - radius * 0.27, item.y - radius * 0.29 }, radius * 0.15,
            imgui.GetColorU32({ 0.94, 0.98, 1.00, alpha * 0.24 }), 10);
    end

    if (state.settings.icon_mode == 'crests') then
        draw_element_crest(
            draw, element.name, item.x, item.y,
            radius * 1.30, luminous_color(color, alpha * 0.98),
            now, state.settings.effects and 1.0 or 0);
    elseif (mechanical) then
        draw_element_crest(
            draw, element.name, item.x, item.y,
            radius * 0.96, luminous_color(color, alpha * 0.98),
            now, state.settings.effects and 0.22 or 0);
    else
        draw_element_glyph(
            draw, element.name, item.x, item.y,
            radius * 1.02, luminous_color(color, alpha * 0.96));
    end
    draw_timer_ring(
        draw, item.x, item.y, radius, remaining,
        item.slot.approximate, color, alpha, now);
end

local function build_render_items(anchor_x, anchor_y, now, overloaded, focus_blend)
    local items = {};
    local count = #state.slots;
    local active_counts = tracked_counts();
    local duplicate_seen = {};
    local radius = state.settings.radius * state.settings.scale;
    local height = state.settings.height * state.settings.scale;
    focus_blend = clamp(focus_blend or 0, 0, 1);
    radius = radius * (1 - 0.08 * focus_blend);
    height = height * (1 - 0.04 * focus_blend);
    local crown_phase = now * state.settings.speed * TAU;
    local orbit_speed = state.settings.style == 'orbit'
        and state.settings.speed or state.settings.deploy_orbit_speed;
    local orbit_phase = now * orbit_speed * TAU;
    local orbit_blend = state.settings.style == 'orbit' and 1
        or (state.settings.deploy_orbit and focus_blend or 0);
    -- Smoothstep keeps both ends of the crown/carousel transition soft.
    local orbit_mix = orbit_blend * orbit_blend * (3 - 2 * orbit_blend);

    for index, slot in ipairs(state.slots) do
        local normalized = count == 1 and 0
            or ((index - 1) / (count - 1)) * 2 - 1;
        local bob = math.sin(crown_phase + (index - 1) * 1.35);
        local crown_depth = bob * 0.22;
        local crown_height = 1.02 - normalized * normalized * 0.30;
        if (count == 3) then
            -- Give the centered second orb a pronounced apex role without
            -- pushing the two side orbs any farther apart vertically.
            crown_height = crown_height + (index == 2 and 0.80 or -0.20);
        end
        local crown_x = anchor_x + normalized * radius
            + math.cos(crown_phase * 0.65 + index) * 1.6;
        local crown_y = anchor_y - height * crown_height + bob * 1.8;

        local orbit_angle = orbit_phase
            + ((index - 1) * TAU / math.max(1, count));
        local orbit_depth = math.sin(orbit_angle);
        local orbit_x = anchor_x + math.cos(orbit_angle) * radius;
        local orbit_y = anchor_y - height * 0.58
            + orbit_depth * height * 0.58;

        local inverse_orbit = 1 - orbit_mix;
        local x = crown_x * inverse_orbit + orbit_x * orbit_mix;
        local y = crown_y * inverse_orbit + orbit_y * orbit_mix;
        local depth = crown_depth * inverse_orbit + orbit_depth * orbit_mix;

        -- When the formation gains or loses an orb, glide surviving orbs from
        -- their previous rendered positions instead of snapping them to their
        -- newly assigned crown/orbit slots.
        if (state.settings.transitions and slot.layout_started ~= nil
            and slot.layout_from_x ~= nil and slot.layout_from_y ~= nil) then
            local progress = clamp(
                (now - slot.layout_started) / TRANSITION_SECONDS, 0, 1);
            if (progress < 1) then
                local blend = progress * progress * (3 - 2 * progress);
                x = slot.layout_from_x * (1 - blend) + x * blend;
                y = slot.layout_from_y * (1 - blend) + y * blend;
                depth = slot.layout_from_depth * (1 - blend) + depth * blend;
            else
                slot.layout_from_x = nil;
                slot.layout_from_y = nil;
                slot.layout_from_depth = nil;
                slot.layout_started = nil;
            end
        elseif (not state.settings.transitions) then
            slot.layout_from_x = nil;
            slot.layout_from_y = nil;
            slot.layout_from_depth = nil;
            slot.layout_started = nil;
        end

        local depth_normal = (depth + 1) * 0.5;
        local base_depth_scale = 0.82 + depth_normal * 0.18;
        local base_alpha = 0.58 + depth_normal * 0.40;
        local entrance = 1;
        if (state.settings.transitions) then
            entrance = clamp(
                (now - (slot.appeared or slot.started))
                    / TRANSITION_SECONDS, 0, 1);
            entrance = 1 - (1 - entrance) * (1 - entrance) * (1 - entrance);
        end
        local risk = state.settings.test_mode and state.settings.test_risk
            or burden_risk(slot.name, overloaded);
        duplicate_seen[slot.name] = (duplicate_seen[slot.name] or 0) + 1;
        local item = {
            slot = slot,
            activation_index = index,
            x = x,
            y = y,
            depth = depth,
            depth_scale = base_depth_scale * (0.72 + entrance * 0.28)
                * (1 + 0.03 * focus_blend),
            alpha = clamp(base_alpha * entrance
                * (1 + 0.08 * focus_blend), 0, 1),
            risk = risk,
            focus_blend = focus_blend,
            orbit_blend = orbit_mix,
            resonance_count = active_counts[slot.name] or 1,
            resonance_index = duplicate_seen[slot.name],
        };
        table.insert(items, item);
        slot.last_x, slot.last_y = x, y;
        slot.last_depth = depth;
        slot.last_depth_scale = base_depth_scale;
        slot.last_alpha = base_alpha;
        slot.last_risk = risk;
        slot.last_focus_blend = focus_blend;
        slot.last_orbit_blend = orbit_mix;
    end

    for index = #state.fading_slots, 1, -1 do
        local slot = state.fading_slots[index];
        local progress = (now - slot.removed_at) / TRANSITION_SECONDS;
        if (progress >= 1 or slot.last_x == nil or slot.last_y == nil) then
            table.remove(state.fading_slots, index);
        else
            local fade = 1 - clamp(progress, 0, 1);
            table.insert(items, {
                slot = slot,
                x = slot.last_x,
                y = slot.last_y,
                depth = slot.last_depth or 0,
                depth_scale = (slot.last_depth_scale or 1) * (0.82 + fade * 0.18),
                alpha = (slot.last_alpha or 0.8) * fade,
                risk = slot.last_risk,
                focus_blend = slot.last_focus_blend or 0,
                orbit_blend = slot.last_orbit_blend or 0,
                departing = true,
            });
        end
    end

    table.sort(items, function(left, right)
        return left.depth < right.depth;
    end);
    return items;
end

local function draw_invocation_lattice(draw, items, now)
    if (not state.settings.lattice) then
        return;
    end

    local active = {};
    for _, item in ipairs(items) do
        if (item.slot ~= nil and not item.departing) then
            table.insert(active, item);
        end
    end
    if (#active ~= 3) then
        return;
    end
    table.sort(active, function(left, right)
        return (left.activation_index or 0) < (right.activation_index or 0);
    end);

    local lattice_risk = 'LOW';
    if (state.settings.burden) then
        for _, item in ipairs(active) do
            local item_risk = item.risk or 'LOW';
            if ((lattice_risk_rank[item_risk] or 1)
                > (lattice_risk_rank[lattice_risk] or 1)) then
                lattice_risk = item_risk;
            end
        end
    end
    local profile = lattice_profiles[lattice_risk] or lattice_profiles.LOW;

    local centroid_x = (active[1].x + active[2].x + active[3].x) / 3;
    local centroid_y = (active[1].y + active[2].y + active[3].y) / 3;
    local formation_alpha = math.min(active[1].alpha, active[2].alpha, active[3].alpha);
    local orbit_blend = clamp(
        ((active[1].orbit_blend or 0)
            + (active[2].orbit_blend or 0)
            + (active[3].orbit_blend or 0)) / 3, 0, 1);
    local pulse = 0.5 + 0.5 * math.sin(now * profile.pulse_speed);
    local controls = {};
    local shadow = imgui.GetColorU32({ 0.002, 0.012, 0.020,
        formation_alpha * clamp(
            (0.30 + pulse * 0.07) * profile.intensity, 0, 0.72) });

    -- Follow formation order around the triangle and bow each edge inward.
    for index = 1, 3 do
        local first = active[index];
        local second = active[index % 3 + 1];
        local mid_x = (first.x + second.x) * 0.5;
        local mid_y = (first.y + second.y) * 0.5;
        local control_x = mid_x + (centroid_x - mid_x) * 0.28;
        local control_y = mid_y + (centroid_y - mid_y) * 0.28;
        if (lattice_risk == 'OVERLOAD') then
            local fracture = math.sin(now * 13.0 + index * 2.1)
                * 3.8 * state.settings.scale;
            control_x = control_x + fracture;
            control_y = control_y - fracture * 0.65;
        end
        controls[index] = { x = control_x, y = control_y };
        local element = elements[first.slot.ability];
        local color = element ~= nil and display_color(element)
            or { 0.72, 0.76, 0.82, 1.00 };
        color = {
            color[1] * (1 - profile.tint_mix) + profile.tint[1] * profile.tint_mix,
            color[2] * (1 - profile.tint_mix) + profile.tint[2] * profile.tint_mix,
            color[3] * (1 - profile.tint_mix) + profile.tint[3] * profile.tint_mix,
            1.00,
        };
        local glow = imgui.GetColorU32(with_alpha(
            color, formation_alpha * clamp(
                (0.16 + pulse * 0.08) * profile.intensity, 0, 0.62)));
        local thread = imgui.GetColorU32(luminous_color(
            color, formation_alpha * clamp(
                (0.34 + pulse * 0.12) * profile.intensity, 0, 0.82)));
        local width = profile.width * state.settings.scale;

        if (draw.AddBezierQuadratic ~= nil) then
            draw:AddBezierQuadratic(
                { first.x, first.y }, { control_x, control_y },
                { second.x, second.y }, shadow,
                math.max(1.0, 3.5 * width), 12);
            draw:AddBezierQuadratic(
                { first.x, first.y }, { control_x, control_y },
                { second.x, second.y }, glow,
                math.max(1.0, 2.4 * width), 12);
            draw:AddBezierQuadratic(
                { first.x, first.y }, { control_x, control_y },
                { second.x, second.y }, thread,
                math.max(1.0, 1.25 * width), 12);
        else
            draw:AddLine({ first.x, first.y }, { second.x, second.y },
                shadow, math.max(1.0, 3.5 * width));
            draw:AddLine({ first.x, first.y }, { second.x, second.y },
                glow, math.max(1.0, 2.4 * width));
            draw:AddLine({ first.x, first.y }, { second.x, second.y },
                thread, math.max(1.0, 1.25 * width));
        end
    end

    -- A compact invocation seal gives the three threads a visible shared core.
    -- Crown geometry is shallow, so hang the seal just below it instead of
    -- allowing the center orb to cover the seal completely.
    local seal_x = centroid_x;
    local seal_y = centroid_y
        + 11.5 * state.settings.scale * (1 - orbit_blend);
    local seal_radius = (4.2 + pulse * 0.9) * state.settings.scale;
    local seal_color = imgui.GetColorU32(with_alpha(profile.tint,
        formation_alpha * clamp(
            (0.54 + pulse * 0.18) * profile.intensity, 0, 0.94)));
    if (seal_y ~= centroid_y) then
        draw:AddLine(
            { centroid_x, centroid_y }, { seal_x, seal_y }, shadow,
            math.max(1.0, 2.6 * state.settings.scale));
        draw:AddLine(
            { centroid_x, centroid_y }, { seal_x, seal_y }, seal_color,
            math.max(1.0, 0.9 * state.settings.scale));
    end
    draw:AddCircleFilled(
        { seal_x, seal_y }, seal_radius + 3.0 * state.settings.scale,
        imgui.GetColorU32(with_alpha(profile.tint,
            formation_alpha * (0.10 + pulse * 0.05))), 18);
    draw:AddCircle(
        { seal_x, seal_y }, seal_radius, seal_color, 18,
        math.max(1.0, 1.25 * state.settings.scale));
    local seal_speed = lattice_risk == 'OVERLOAD'
        and 2.20 or math.max(0.42, profile.circuit_speed * 0.70);
    local seal_phase = -now * seal_speed;
    local seal_points = {};
    for index = 0, 2 do
        local angle = seal_phase + index * TAU / 3;
        seal_points[index + 1] = {
            seal_x + math.cos(angle) * seal_radius * 0.72,
            seal_y + math.sin(angle) * seal_radius * 0.72,
        };
    end
    for index = 1, 3 do
        draw:AddLine(seal_points[index], seal_points[index % 3 + 1],
            seal_color, math.max(1.0, 0.95 * state.settings.scale));
    end
    draw:AddCircleFilled(
        { seal_x, seal_y }, 1.25 * state.settings.scale,
        seal_color, 8);

    if (lattice_risk == 'OVERLOAD') then
        -- Overload destroys the orderly circuit: the center vents irregular
        -- red sparks instead of presenting another readable orbit.
        local spark_color = imgui.GetColorU32(with_alpha(
            profile.tint, formation_alpha * (0.52 + pulse * 0.28)));
        for index = 0, 5 do
            local angle = now * 2.8 + index * TAU / 6
                + math.sin(now * 11.0 + index * 2.3) * 0.18;
            local flicker = 0.5 + 0.5 * math.sin(now * 15.0 + index * 1.7);
            local inner = seal_radius + 2.0 * state.settings.scale;
            local outer = inner + (4.0 + flicker * 8.0) * state.settings.scale;
            draw_radial_line(draw, seal_x, seal_y, inner, outer, angle,
                spark_color, math.max(1.0, 1.35 * state.settings.scale));
            draw:AddCircleFilled({
                seal_x + math.cos(angle) * outer,
                seal_y + math.sin(angle) * outer,
            }, (0.7 + flicker * 0.8) * state.settings.scale,
                spark_color, 8);
        end
        return;
    end

    -- One mote traces the three edges in formation order. Its speed conveys
    -- burden state, while the outer orbital mote remains the exact recast clock.
    local cycle = (now * profile.circuit_speed) % 3;
    local edge_index = math.floor(cycle) + 1;
    local progress = cycle - math.floor(cycle);
    local first = active[edge_index];
    local second = active[edge_index % 3 + 1];
    local control = controls[edge_index];
    local inverse = 1 - progress;
    local mote_x = inverse * inverse * first.x
        + 2 * inverse * progress * control.x
        + progress * progress * second.x;
    local mote_y = inverse * inverse * first.y
        + 2 * inverse * progress * control.y
        + progress * progress * second.y;
    local destination = elements[second.slot.ability];
    local mote_color = destination ~= nil and display_color(destination)
        or { 0.86, 0.90, 0.96, 1.00 };
    mote_color = {
        mote_color[1] * (1 - profile.tint_mix) + profile.tint[1] * profile.tint_mix,
        mote_color[2] * (1 - profile.tint_mix) + profile.tint[2] * profile.tint_mix,
        mote_color[3] * (1 - profile.tint_mix) + profile.tint[3] * profile.tint_mix,
        1.00,
    };
    draw:AddCircleFilled(
        { mote_x, mote_y }, (4.0 + pulse * 0.8) * state.settings.scale,
        imgui.GetColorU32(with_alpha(
            mote_color, formation_alpha * clamp(
                (0.16 + pulse * 0.08) * profile.intensity, 0, 0.54))), 12);
    draw:AddCircleFilled(
        { mote_x, mote_y }, 2.15 * state.settings.scale,
        imgui.GetColorU32(luminous_color(
            mote_color, formation_alpha * clamp(
                (0.74 + pulse * 0.18) * profile.intensity, 0, 1.00))), 10);
end

local function draw_duplicate_resonance(draw, items, now)
    -- Treat every inter-orb connection as part of the lattice presentation.
    -- Otherwise duplicate maneuvers can leave lattice-like threads visible
    -- after the user explicitly disables the lattice.
    if (not state.settings.lattice) then
        return;
    end

    local groups = {};
    for _, item in ipairs(items) do
        if (item.slot ~= nil and not item.departing
            and (item.resonance_count or 1) > 1) then
            local name = item.slot.name;
            groups[name] = groups[name] or {};
            table.insert(groups[name], item);
        end
    end

    for name, group in pairs(groups) do
        table.sort(group, function(left, right)
            return left.slot.started < right.slot.started;
        end);
        local element = by_name[string.lower(name)];
        -- A three-of-a-kind formation is already fully represented by the
        -- lattice; avoid drawing a second triangle directly beneath it.
        if (state.settings.lattice and #group == 3) then
            element = nil;
        end
        if (element ~= nil) then
            local color = display_color(element);
            local pulse = 0.5 + 0.5 * math.sin(now * 1.7 + element.ability);
            local thread = imgui.GetColorU32(with_alpha(color, 0.10 + pulse * 0.10));
            local mote = imgui.GetColorU32(luminous_color(color, 0.42 + pulse * 0.18));
            local edge_count = #group == 3 and 3 or (#group - 1);
            for index = 1, edge_count do
                local first = group[index];
                local second = group[index % #group + 1];
                local mid_x = (first.x + second.x) * 0.5;
                local mid_y = (first.y + second.y) * 0.5
                    - (8 + pulse * 4) * state.settings.scale;
                if (draw.AddBezierQuadratic ~= nil) then
                    draw:AddBezierQuadratic(
                        { first.x, first.y }, { mid_x, mid_y },
                        { second.x, second.y }, thread,
                        math.max(1.0, state.settings.scale), 12);
                else
                    draw:AddLine({ first.x, first.y }, { second.x, second.y },
                        thread, math.max(1.0, state.settings.scale));
                end

                local progress = (now * 0.28 + index * 0.31) % 1;
                local inverse = 1 - progress;
                local mote_x = inverse * inverse * first.x
                    + 2 * inverse * progress * mid_x
                    + progress * progress * second.x;
                local mote_y = inverse * inverse * first.y
                    + 2 * inverse * progress * mid_y
                    + progress * progress * second.y;
                draw:AddCircleFilled({ mote_x, mote_y },
                    1.45 * state.settings.scale, mote, 8);
            end
        end
    end
end

local function draw_deploy_chevrons(draw, items, focus_blend, now)
    focus_blend = clamp(focus_blend or 0, 0, 1);
    if (focus_blend <= 0.01) then
        return;
    end

    local active = {};
    for _, item in ipairs(items) do
        if (item.slot ~= nil and not item.departing) then
            table.insert(active, item);
        end
    end
    if (#active == 0) then
        return;
    end

    local min_x, max_x = math.huge, -math.huge;
    local left_y, right_y = 0, 0;
    local formation_alpha = 1;
    for _, item in ipairs(active) do
        if (item.x < min_x) then
            min_x, left_y = item.x, item.y;
        end
        if (item.x > max_x) then
            max_x, right_y = item.x, item.y;
        end
        formation_alpha = math.min(formation_alpha, item.alpha or 1);
    end
    local center_y = (left_y + right_y) * 0.5;

    local scale = state.settings.scale;
    -- Keep the inner tips beyond the orb shell and segmented timer ring.
    local gap = (38 - focus_blend * 8) * scale;
    local half_height = 8.0 * scale;
    local depth = 7.5 * scale;
    local pulse = 0.5 + 0.5 * math.sin(now * 2.1);
    local alpha = formation_alpha * focus_blend * (0.58 + pulse * 0.10);
    local shadow = imgui.GetColorU32({ 0.002, 0.012, 0.018, alpha * 0.78 });
    local brass = imgui.GetColorU32({ 0.86, 0.65, 0.30, alpha * 0.72 });
    local teal = imgui.GetColorU32({ 0.38, 0.92, 0.82, alpha });

    local left_outer = min_x - gap;
    local left_tip = left_outer + depth;
    local right_outer = max_x + gap;
    local right_tip = right_outer - depth;
    local segments = {
        { { left_outer, center_y - half_height }, { left_tip, center_y } },
        { { left_tip, center_y }, { left_outer, center_y + half_height } },
        { { right_outer, center_y - half_height }, { right_tip, center_y } },
        { { right_tip, center_y }, { right_outer, center_y + half_height } },
    };
    for _, segment in ipairs(segments) do
        draw:AddLine(segment[1], segment[2], shadow,
            math.max(1.0, 4.0 * scale));
        draw:AddLine(segment[1], segment[2], brass,
            math.max(1.0, 2.2 * scale));
        draw:AddLine(segment[1], segment[2], teal,
            math.max(1.0, 1.0 * scale));
    end
    draw:AddCircleFilled({ left_tip, center_y }, 1.35 * scale, teal, 8);
    draw:AddCircleFilled({ right_tip, center_y }, 1.35 * scale, teal, 8);
end

local function draw_deploy_seals(draw, items, focus_blend, now)
    focus_blend = clamp(focus_blend or 0, 0, 1);
    if (focus_blend <= 0.01) then
        return;
    end

    local scale = state.settings.scale;
    for index, item in ipairs(items) do
        if (item.slot ~= nil and not item.departing) then
            local depth_scale = item.depth_scale or 1;
            -- The seal's perimeter sits outside the largest elemental shell and
            -- timer ring, while its center remains concealed behind the orb.
            local radius = 25.0 * scale * depth_scale;
            local settle = (1 - focus_blend) * 0.32;
            local motion_time = state.settings.effects and now or 0;
            local phase = motion_time * 0.060 + settle + (index - 1) * 0.10;
            local inner_phase = -motion_time * 0.040
                + settle * 0.55 + (index - 1) * 0.10;
            local pulse = state.settings.effects
                and (0.5 + 0.5 * math.sin(now * 1.65 + index * 0.7)) or 0.5;
            local alpha = item.alpha * focus_blend * (0.58 + pulse * 0.10);
            local shadow = imgui.GetColorU32({
                0.002, 0.010, 0.016, alpha * 0.88,
            });
            local brass = imgui.GetColorU32({
                0.96, 0.72, 0.24, alpha * 0.96,
            });
            local copper = imgui.GetColorU32({
                0.68, 0.36, 0.12, alpha * 0.76,
            });
            local dark_brass = imgui.GetColorU32({
                0.48, 0.30, 0.10, alpha * 0.64,
            });
            local turquoise = imgui.GetColorU32({
                0.22, 0.78, 0.70, alpha * 0.60,
            });

            -- Eight broken imperial arcs form an aged astrolabe perimeter.
            for segment = 0, 7 do
                local angle = phase + segment * TAU / 8;
                draw_arc(draw, item.x, item.y, radius,
                    angle + 0.08, angle + TAU / 8 - 0.12,
                    shadow, math.max(1.0, 4.0 * scale), 5);
                draw_arc(draw, item.x, item.y, radius,
                    angle + 0.08, angle + TAU / 8 - 0.12,
                    brass, math.max(1.0, 2.25 * scale), 5);
                draw_radial_line(draw, item.x, item.y,
                    radius * 0.91,
                    radius * (segment % 2 == 0 and 1.15 or 1.10),
                    angle, copper, math.max(1.0, 1.75 * scale));
                draw:AddCircleFilled({
                    item.x + math.cos(angle) * radius * 0.91,
                    item.y + math.sin(angle) * radius * 0.91,
                }, 1.15 * scale, brass, 8);
            end

            -- Four inset copper rails add the layered platework of a compact
            -- gear housing without becoming another complete timer circle.
            for rail = 0, 3 do
                local angle = inner_phase + rail * TAU / 4;
                draw_arc(draw, item.x, item.y, radius * 0.88,
                    angle + 0.14, angle + 0.92,
                    dark_brass, math.max(1.0, 2.8 * scale), 6);
                draw_arc(draw, item.x, item.y, radius * 0.88,
                    angle + 0.14, angle + 0.92,
                    copper, math.max(1.0, 1.25 * scale), 6);
            end

            -- A turquoise diamond and offset brass square suggest the
            -- interlocked geometry of an Aht Urhgan automaton workshop seal.
            local diamond = {};
            local square = {};
            for point = 0, 3 do
                local diamond_angle = inner_phase
                    + math.pi * 0.25 + point * TAU / 4;
                local square_angle = inner_phase + point * TAU / 4;
                diamond[point + 1] = {
                    item.x + math.cos(diamond_angle) * radius * 0.84,
                    item.y + math.sin(diamond_angle) * radius * 0.84,
                };
                square[point + 1] = {
                    item.x + math.cos(square_angle) * radius * 0.77,
                    item.y + math.sin(square_angle) * radius * 0.77,
                };
            end
            for point = 1, 4 do
                draw:AddLine(diamond[point], diamond[point % 4 + 1],
                    shadow, math.max(1.0, 3.2 * scale));
                draw:AddLine(diamond[point], diamond[point % 4 + 1],
                    brass, math.max(1.0, 1.45 * scale));
                draw:AddLine(square[point], square[point % 4 + 1],
                    copper, math.max(1.0, 1.15 * scale));
            end

            for rivet = 0, 3 do
                local angle = phase + math.pi * 0.25 + rivet * TAU / 4;
                draw:AddCircleFilled({
                    item.x + math.cos(angle) * radius,
                    item.y + math.sin(angle) * radius,
                }, 1.35 * scale, rivet % 2 == 0 and brass or turquoise, 8);
            end
        end
    end
end

local function keep_items_in_safe_area(items, viewport)
    if (not state.settings.safearea or viewport == nil or #items == 0) then
        return;
    end

    local extent = 30 * state.settings.scale;
    local min_x, min_y = math.huge, math.huge;
    local max_x, max_y = -math.huge, -math.huge;
    for _, item in ipairs(items) do
        min_x = math.min(min_x, item.x - extent);
        max_x = math.max(max_x, item.x + extent);
        min_y = math.min(min_y, item.y - extent);
        max_y = math.max(max_y, item.y + extent);
    end

    local edge = 8;
    local left = viewport.X + edge;
    local right = viewport.X + viewport.Width - edge;
    local top = viewport.Y + edge;
    local bottom = viewport.Y + viewport.Height - edge;
    local shift_x, shift_y = 0, 0;
    if (min_x < left) then
        shift_x = left - min_x;
    elseif (max_x > right) then
        shift_x = right - max_x;
    end
    if (min_y < top) then
        shift_y = top - min_y;
    elseif (max_y > bottom) then
        shift_y = bottom - max_y;
    end

    if (shift_x ~= 0 or shift_y ~= 0) then
        for _, item in ipairs(items) do
            item.x = item.x + shift_x;
            item.y = item.y + shift_y;
        end
    end

    for _, item in ipairs(items) do
        if (item.slot ~= nil and not item.departing) then
            item.slot.last_x, item.slot.last_y = item.x, item.y;
        end
    end
end

local function render()
    local is_pup, alive, zoning, engaged = get_player_state();
    local preview = state.settings.test_mode;
    if (zoning or (not is_pup and not preview) or not alive) then
        if (state.was_zoning ~= zoning or state.was_pup ~= is_pup
            or state.was_alive ~= alive) then
            clear_slots();
        end
        state.was_pup = is_pup;
        state.was_alive = alive;
        state.was_zoning = zoning;
        return;
    end

    state.was_pup = is_pup;
    state.was_alive = true;
    state.was_zoning = false;
    if (preview) then
        ensure_test_slots(false);
    else
        reconcile_slots(false);
    end
    if (not state.settings.enabled
        or (#state.slots == 0 and #state.fading_slots == 0)) then
        return;
    end

    if (should_auto_hide()) then
        state.anchor_x, state.anchor_y, state.anchor_time = nil, nil, 0;
        state.idle_blend, state.engagement_time = nil, 0;
        state.deploy_blend, state.deploy_time = nil, 0;
        return;
    end

    local anchor_x, anchor_y, viewport = safe_anchor();
    if (anchor_x == nil or anchor_y == nil) then
        return;
    end
    local now = clock_seconds();
    anchor_x, anchor_y = smooth_anchor(anchor_x, anchor_y, now);

    -- Positive screen-space Y moves the formation down toward the character.
    -- Blend the idle adjustment so engagement camera changes do not snap.
    local idle_blend = smooth_engagement_offset(engaged, now);
    anchor_y = anchor_y + state.settings.offset_y
        + state.settings.idle_offset_y * idle_blend;

    local draw = imgui.GetBackgroundDrawList();
    if (draw == nil) then
        return;
    end

    local _, overloaded = current_buff_counts();
    if (preview) then
        overloaded = state.settings.test_risk == 'OVERLOAD';
    end
    local deployed = false;
    if (preview) then
        deployed = state.settings.test_deployed;
    else
        deployed = automaton_is_deployed();
    end
    local focus_blend = smooth_deploy_focus(deployed, now);
    local items = build_render_items(
        anchor_x, anchor_y, now, overloaded, focus_blend);
    keep_items_in_safe_area(items, viewport);
    if (state.settings.deploy_style == 'chevrons') then
        draw_deploy_chevrons(draw, items, focus_blend, now);
    else
        draw_deploy_seals(draw, items, focus_blend, now);
    end
    draw_shared_recast_mote(draw, items, now);
    draw_invocation_lattice(draw, items, now);
    draw_duplicate_resonance(draw, items, now);
    for _, item in ipairs(items) do
        draw_orb(draw, item, now);
    end
    draw_confirmation_flash(draw, items, now);
    draw_overload_flash(draw, anchor_x, anchor_y, now);
end

local function parse_switch(value, current)
    value = string.lower(value or 'toggle');
    if (value == 'on') then
        return true;
    elseif (value == 'off') then
        return false;
    elseif (value == 'toggle') then
        return not current;
    end
    return nil;
end

local function apply_visual_preset(name)
    local preset = visual_presets[name];
    if (preset == nil) then
        return false;
    end
    for key, value in pairs(preset) do
        state.settings[key] = value;
    end
    state.anchor_x, state.anchor_y, state.anchor_time = nil, nil, 0;
    return true;
end

local function print_help()
    local lines = {
        '/aa on | off | toggle',
        '/aa style crown | orbit',
        '/aa icons runes | crests | mechanical | toggle',
        '/aa preset taru | compact | cinematic',
        '/aa radius <20-180> | height <10-140>',
        '/aa speed <0.00-1.00> | scale <0.50-2.50>',
        '/aa offset <-500..500> - negative moves above the origin',
        '/aa idleoffset <-200..200> - added only while not engaged',
        '/aa timers on | off',
        '/aa recast on | off',
        '/aa effects on | off',
        '/aa transitions on | off | smoothing <0.00-0.50>',
        '/aa burden on | off',
        '/aa lattice on | off',
        '/aa deployfx on | off | toggle',
        '/aa deploystyle seals | chevrons',
        '/aa deployorbit on | off | toggle',
        '/aa orbitspeed <0.01-0.25>',
        '/aa confirmflash on | off | toggle',
        '/aa colorblind on | off',
        '/aa fallback on | off',
        '/aa safearea on | off',
        '/aa autohide on | off',
        '/aa test on | off | status | recast',
        '/aa test deploy on | off | toggle',
        '/aa test flash [element]',
        '/aa test count <1-3> | risk <low|warm|danger|overload>',
        '/aa test set <element> <element> <element>',
        '/aa reset | help',
    };
    message('Commands:');
    for _, line in ipairs(lines) do
        print(chat.header(DISPLAY_NAME):append(chat.color1(6, line)));
    end
end

settings.register('settings', 'settings_update', function(s)
    if (s ~= nil) then
        state.settings = s;
    end
    ensure_settings_shape();
end);

ashita.events.register('load', 'load_cb', function()
    ensure_settings_shape();
    if (state.settings.test_mode) then
        ensure_test_slots(true);
    else
        reconcile_slots(true);
    end
    settings.save();
    if (state.settings.test_mode) then
        message('Loaded with test preview active. Use /aa test off to resume live tracking.');
    else
        message('Loaded. Type /aa help for commands.');
    end
end);

ashita.events.register('unload', 'unload_cb', function()
    clear_slots();
    settings.save();
end);

ashita.events.register('packet_in', 'packet_in_cb', function(e)
    if (e.id == 0x000A or e.id == 0x000B) then
        clear_slots();
        state.last_sync = -1;
        return;
    end

    if (state.settings.test_mode) then
        return;
    end

    if (e.id ~= 0x0028) then
        return;
    end

    local ok, packet = pcall(actionpacket.parse, e);
    if (not ok or packet == nil or packet.Id < MANEUVER_MIN_ID
        or packet.Id > MANEUVER_MAX_ID) then
        return;
    end

    local player = GetPlayerEntity();
    if (player == nil or packet.UserId ~= player.ServerId) then
        return;
    end

    local element = elements[packet.Id];
    for _, target in ipairs(packet.Targets) do
        for _, action in ipairs(target.Actions) do
            -- 798 is a successful maneuver. 799 is an overload failure.
            if (action.Message == 798) then
                local now = clock_seconds();
                local before_counts = tracked_counts();
                state.last_action = now;
                record_overload_chance(element, action.Param);
                local immediate_slot = apply_immediate_maneuver(
                    element, before_counts, now);
                if (immediate_slot ~= nil) then
                    state.pending_sync = nil;
                    confirm_maneuver_slot(immediate_slot, now);
                else
                    state.pending_sync = {
                        element = element,
                        before_counts = before_counts,
                        seen = now,
                    };
                end
                return;
            elseif (action.Message == 799) then
                state.last_action = clock_seconds();
                state.pending_sync = nil;
                record_overload_chance(element, action.Param);
                state.overload_flash = {
                    ability = element.ability,
                    started = state.last_action,
                };
                return;
            end
        end
    end
end);

ashita.events.register('command', 'command_cb', function(e)
    local args = e.command:args();
    if (#args == 0) then
        return;
    end

    local root = string.lower(args[1]);
    if (root ~= '/aa' and root ~= '/arcaneautomata'
        and root ~= '/po' and root ~= '/puporbit'
        and root ~= '/invokation' and root ~= '/inv') then
        return;
    end
    e.blocked = true;

    local command = string.lower(args[2] or 'toggle');
    if (command == 'on' or command == 'off' or command == 'toggle') then
        state.settings.enabled = parse_switch(command, state.settings.enabled);
        message('Display: ' .. (state.settings.enabled and 'on.' or 'off.'));
    elseif (command == 'style') then
        local style = string.lower(args[3] or '');
        if (style ~= 'crown' and style ~= 'orbit') then
            error_message('Use /aa style crown or /aa style orbit.');
            return;
        end
        state.settings.style = style;
        message('Style: ' .. style .. '.');
    elseif (command == 'icons') then
        local mode = string.lower(args[3] or 'toggle');
        if (mode == 'toggle') then
            mode = state.settings.icon_mode == 'runes' and 'crests'
                or state.settings.icon_mode == 'crests' and 'mechanical'
                or 'runes';
        end
        -- Preserve the original command name as a compatibility alias.
        if (mode == 'vector') then
            mode = 'runes';
        end
        if (mode ~= 'runes' and mode ~= 'crests' and mode ~= 'mechanical') then
            error_message(
                'Use /aa icons runes, crests, mechanical, or toggle.');
            return;
        end
        state.settings.icon_mode = mode;
        message('Center icons: ' .. mode .. '.');
    elseif (command == 'preset') then
        local preset = string.lower(args[3] or '');
        if (not apply_visual_preset(preset)) then
            error_message('Use /aa preset taru, compact, or cinematic.');
            return;
        end
        message('Visual preset: ' .. preset .. '.');
    elseif (command == 'deploystyle') then
        local style = string.lower(args[3] or '');
        if (style ~= 'seals' and style ~= 'chevrons') then
            error_message('Use /aa deploystyle seals or chevrons.');
            return;
        end
        state.settings.deploy_style = style;
        message('Deploy effect: ' .. style .. '.');
    elseif (command == 'radius' or command == 'height'
        or command == 'speed' or command == 'scale'
        or command == 'offset' or command == 'idleoffset'
        or command == 'smoothing' or command == 'orbitspeed') then
        local value = tonumber(args[3]);
        if (value == nil) then
            error_message('Use /aa ' .. command .. ' <number>.');
            return;
        end
        if (command == 'radius') then
            state.settings.radius = clamp(value, 20, 180);
        elseif (command == 'height') then
            state.settings.height = clamp(value, 10, 140);
        elseif (command == 'speed') then
            state.settings.speed = clamp(value, 0, 1.0);
        elseif (command == 'offset') then
            state.settings.offset_y = clamp(value, -500, 500);
        elseif (command == 'idleoffset') then
            state.settings.idle_offset_y = clamp(value, -200, 200);
        elseif (command == 'smoothing') then
            state.settings.smoothing = clamp(value, 0, 0.50);
            state.anchor_x, state.anchor_y, state.anchor_time = nil, nil, 0;
        elseif (command == 'orbitspeed') then
            state.settings.deploy_orbit_speed = clamp(value, 0.01, 0.25);
        else
            state.settings.scale = clamp(value, 0.5, 2.5);
        end
        local setting_key = command == 'offset' and 'offset_y'
            or command == 'idleoffset' and 'idle_offset_y'
            or command == 'orbitspeed' and 'deploy_orbit_speed'
            or command;
        message(string.format('%s: %.2f.', command, state.settings[setting_key]));
    elseif (command == 'timers' or command == 'recast' or command == 'effects'
        or command == 'transitions' or command == 'burden'
        or command == 'lattice' or command == 'deployfx'
        or command == 'deployorbit' or command == 'confirmflash'
        or command == 'colorblind' or command == 'fallback'
        or command == 'safearea' or command == 'autohide') then
        local setting_key = command == 'recast' and 'recast_ring'
            or command == 'deployfx' and 'deploy_focus'
            or command == 'deployorbit' and 'deploy_orbit'
            or command == 'confirmflash' and 'confirmation_flash'
            or command;
        local value = parse_switch(args[3], state.settings[setting_key]);
        if (value == nil) then
            error_message('Use /aa ' .. command .. ' on or /aa ' .. command .. ' off.');
            return;
        end
        state.settings[setting_key] = value;
        message(command .. ': ' .. (value and 'on.' or 'off.'));
    elseif (command == 'test') then
        local option = string.lower(args[3] or 'toggle');
        if (option == 'on' or option == 'off' or option == 'toggle') then
            local enabled = parse_switch(option, state.settings.test_mode);
            state.settings.test_mode = enabled;
            clear_slots();
            state.last_sync = -1;
            if (enabled) then
                state.settings.enabled = true;
                ensure_test_slots(true);
                state.last_action = clock_seconds();
            else
                state.last_action = -10;
            end
            message('Test preview: ' .. (enabled and 'on.' or 'off.'));
        elseif (option == 'status') then
            message(('Test preview: %s | %d orb%s | %s burden | %s'):fmt(
                state.settings.test_mode and 'on' or 'off',
                state.settings.test_count,
                state.settings.test_count == 1 and '' or 's',
                state.settings.test_risk,
                table.concat(state.settings.test_elements, '/'))
                .. ' | ' .. (state.settings.test_deployed
                    and 'deployed' or 'idle')
                .. ' | carousel '
                .. (state.settings.deploy_orbit and 'on' or 'off'));
        elseif (option == 'count') then
            local count = tonumber(args[4]);
            if (count == nil or count < 1 or count > 3) then
                error_message('Use /aa test count 1, 2, or 3.');
                return;
            end
            state.settings.test_count = math.floor(count);
            state.settings.test_mode = true;
            state.settings.enabled = true;
            ensure_test_slots(true);
            message(('Test preview: %d orb%s.'):fmt(
                state.settings.test_count,
                state.settings.test_count == 1 and '' or 's'));
        elseif (option == 'risk') then
            local risk = string.upper(args[4] or '');
            if (lattice_profiles[risk] == nil) then
                error_message('Use /aa test risk low, warm, danger, or overload.');
                return;
            end
            state.settings.test_risk = risk;
            state.settings.test_mode = true;
            state.settings.enabled = true;
            ensure_test_slots(false);
            message('Test burden: ' .. risk .. '.');
        elseif (option == 'set') then
            local selected = T{};
            for index = 1, 3 do
                local element = by_name[string.lower(args[index + 3] or '')];
                if (element == nil) then
                    error_message(
                        'Use /aa test set <element> <element> <element>.');
                    return;
                end
                selected[index] = element.name;
            end
            state.settings.test_elements = selected;
            state.settings.test_count = 3;
            state.settings.test_mode = true;
            state.settings.enabled = true;
            ensure_test_slots(true);
            message('Test elements: ' .. table.concat(selected, '/'));
        elseif (option == 'recast') then
            state.settings.test_mode = true;
            state.settings.enabled = true;
            ensure_test_slots(false);
            state.last_action = clock_seconds();
            state.recast_was_active = false;
            state.recast_ready_at = -10;
            message('Test maneuver recast restarted.');
        elseif (option == 'deploy') then
            local deployed = parse_switch(
                args[4], state.settings.test_deployed);
            if (deployed == nil) then
                error_message('Use /aa test deploy on, off, or toggle.');
                return;
            end
            state.settings.test_mode = true;
            state.settings.enabled = true;
            state.settings.test_deployed = deployed;
            ensure_test_slots(false);
            message('Test deploy state: '
                .. (deployed and 'deployed.' or 'idle.'));
        elseif (option == 'flash') then
            state.settings.test_mode = true;
            state.settings.enabled = true;
            ensure_test_slots(false);
            local requested = string.lower(args[4] or '');
            local slot = nil;
            if (requested ~= '') then
                local element = by_name[requested];
                if (element == nil) then
                    error_message('Use /aa test flash [element].');
                    return;
                end
                for _, candidate in ipairs(state.slots) do
                    if (candidate.ability == element.ability) then
                        slot = candidate;
                        break;
                    end
                end
                if (slot == nil) then
                    error_message(element.name
                        .. ' is not in the current test formation.');
                    return;
                end
            else
                slot = state.slots[#state.slots];
            end
            state.confirmation_flash = {
                slot = slot,
                started = clock_seconds(),
            };
            message('Test confirmation flash.');
        else
            error_message(
                'Use /aa test on, off, status, count, risk, set, recast, deploy, or flash.');
            return;
        end
    elseif (command == 'reset') then
        settings.reset();
        clear_slots();
        state.last_sync = -1;
        message('Settings and tracked timers reset.');
    elseif (command == 'help') then
        print_help();
    else
        print_help();
    end
    settings.save();
end);

ashita.events.register('d3d_present', 'present_cb', function()
    local ok, err = pcall(render);
    if (not ok) then
        -- Rendering fails closed, while packet tracking and commands continue.
        -- Report a persistent error once instead of flooding the game console.
        if (state.last_render_error ~= tostring(err)) then
            state.last_render_error = tostring(err);
            error_message('Render error: ' .. state.last_render_error);
        end
        return;
    end
    state.last_render_error = nil;
end);
