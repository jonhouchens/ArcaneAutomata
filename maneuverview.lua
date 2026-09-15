-- Stateless view of the player's maneuver buffs as maintained by Ashita.
--
-- This module deliberately owns no maneuver lifecycle state. Every call reads
-- the current 32-slot buff and status-timer arrays, pairs them by index, and
-- returns a short-lived derived view for the caller.

local bit = require('bit');

local lib = {};

local OVERLOAD_BUFF_ID = 299;
local FIRST_MANEUVER_BUFF_ID = 300;
local LAST_MANEUVER_BUFF_ID = 307;
local MANEUVER_DURATION_SECONDS = 60;
local MAX_ACTIVE_MANEUVERS = 3;
local INFINITE_DURATION = 0x7FFFFFFF;
local VANA_BASE_STAMP = 0x3C307D70;
local UINT32 = 0x100000000;
local INT32_MIN = -0x80000000;
local INT32_MAX = 0x7FFFFFFF;

local element_names = {
    [300] = 'Fire',
    [301] = 'Ice',
    [302] = 'Wind',
    [303] = 'Earth',
    [304] = 'Thunder',
    [305] = 'Water',
    [306] = 'Light',
    [307] = 'Dark',
};

local utc_pointer = nil;

local function empty_view(now, error_text)
    return {
        read_at = now,
        counts = {},
        maneuvers = {},
        oldest = nil,
        overloaded = false,
        timer_available = false,
        raw_maneuver_count = 0,
        trimmed_maneuver_count = 0,
        error = error_text,
    };
end

local function find_utc_pointer()
    if (utc_pointer ~= nil) then
        return utc_pointer;
    end
    local ok, pointer = pcall(ashita.memory.find,
        'FFXiMain.dll', 0,
        '8B0D????????8B410C8B49108D04808D04808D04808D04C1C3', 2, 0);
    utc_pointer = ok and pointer or 0;
    return utc_pointer;
end

local function game_utcstamp()
    local pointer = find_utc_pointer();
    if (pointer == nil or pointer == 0) then
        return nil;
    end
    local ok, value = pcall(function()
        local first = ashita.memory.read_uint32(pointer);
        if (first == nil or first == 0) then return nil; end
        local second = ashita.memory.read_uint32(first);
        if (second == nil or second == 0) then return nil; end
        return ashita.memory.read_uint32(second + 0x0C);
    end);
    return ok and value or nil;
end

-- Convert the raw absolute status-timer representation used by the client to
-- seconds remaining. This is the same epoch/tick conversion used by the
-- established Ashita StatusTimers and Timers addons.
function lib.remaining_seconds(raw_duration, utcstamp)
    if (raw_duration == nil or utcstamp == nil
        or raw_duration == INFINITE_DURATION) then
        return nil;
    end

    local raw = tonumber(raw_duration);
    if (raw == nil) then return nil; end
    if (raw < 0) then raw = raw + UINT32; end

    local comparand = bit.band((utcstamp - VANA_BASE_STAMP) * 60, 0xFFFFFFFF);
    if (comparand < 0) then comparand = comparand + UINT32; end
    local remaining_ticks = raw - comparand;
    if (remaining_ticks < INT32_MIN) then
        remaining_ticks = remaining_ticks + UINT32;
    elseif (remaining_ticks > INT32_MAX) then
        remaining_ticks = remaining_ticks - UINT32;
    end
    if (remaining_ticks < 1) then return 0; end
    return math.ceil(remaining_ticks / 60);
end

function lib.from_arrays(buffs, timers, options)
    options = options or {};
    local now = options.now or os.clock();
    if (buffs == nil or timers == nil) then
        return empty_view(now, 'Ashita buff or timer array unavailable');
    end

    local utcstamp = options.utcstamp;
    local view = empty_view(now, nil);
    for index = 1, 32 do
        local buff_id = tonumber(buffs[index]);
        if (buff_id == OVERLOAD_BUFF_ID) then
            view.overloaded = true;
        elseif (buff_id ~= nil and buff_id >= FIRST_MANEUVER_BUFF_ID
            and buff_id <= LAST_MANEUVER_BUFF_ID) then
            local name = element_names[buff_id];
            local remaining = lib.remaining_seconds(timers[index], utcstamp);
            -- A maneuver cannot legitimately exceed its 60-second lifetime.
            -- Reject implausible values rather than publishing a false stable
            -- timer if the client timer layout or clock signature ever changes.
            local timer_valid = remaining ~= nil
                and remaining >= 0
                and remaining <= MANEUVER_DURATION_SECONDS + 5;
            local instance = {
                name = name,
                buff_id = buff_id,
                buff_index = index,
                raw_timer = timers[index],
                remaining = timer_valid and remaining or nil,
                expires = timer_valid and (now + remaining) or nil,
                started = timer_valid
                    and (now + remaining - MANEUVER_DURATION_SECONDS) or nil,
                approximate = not timer_valid,
            };
            table.insert(view.maneuvers, instance);
            if (timer_valid) then view.timer_available = true; end
        end
    end

    table.sort(view.maneuvers, function(left, right)
        if (left.expires == nil) ~= (right.expires == nil) then
            return left.expires ~= nil;
        elseif (left.expires ~= nil and left.expires ~= right.expires) then
            return left.expires < right.expires;
        end
        return left.buff_index < right.buff_index;
    end);

    -- When a fourth maneuver replaces the oldest, Ashita can expose the new
    -- buff one frame before clearing the outgoing buff slot. Normalize that
    -- transient snapshot to the game's three-maneuver cap immediately. Since
    -- the list is expiration-ordered, the outgoing oldest instance is first.
    view.raw_maneuver_count = #view.maneuvers;
    while (#view.maneuvers > MAX_ACTIVE_MANEUVERS) do
        table.remove(view.maneuvers, 1);
        view.trimmed_maneuver_count = view.trimmed_maneuver_count + 1;
    end

    view.timer_available = false;
    for _, instance in ipairs(view.maneuvers) do
        view.counts[instance.name] = (view.counts[instance.name] or 0) + 1;
        if (not instance.approximate) then view.timer_available = true; end
    end
    view.oldest = view.maneuvers[1];
    return view;
end

function lib.read(options)
    options = options or {};
    local now = options.now or os.clock();
    local player = options.player;
    if (player == nil) then
        local ok, value = pcall(function()
            return AshitaCore:GetMemoryManager():GetPlayer();
        end);
        player = ok and value or nil;
    end
    if (player == nil) then
        return empty_view(now, 'Ashita player memory unavailable');
    end

    local ok, buffs, timers = pcall(function()
        return player:GetBuffs(), player:GetStatusTimers();
    end);
    if (not ok) then return empty_view(now, tostring(buffs)); end

    return lib.from_arrays(buffs, timers, {
        now = now,
        utcstamp = options.utcstamp or game_utcstamp(),
    });
end

return lib;
