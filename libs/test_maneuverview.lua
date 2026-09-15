package.path = '../?.lua;./?.lua;' .. package.path;

local bit = require('bit');
local maneuverview = require('maneuverview');

local BASE = 0x3C307D70;
local utc = BASE + 100000;
local now = 500;

local function raw_timer(seconds)
    return bit.band((utc - BASE) * 60 + seconds * 60, 0xFFFFFFFF);
end

local function arrays(entries)
    local buffs, timers = {}, {};
    for index = 1, 32 do
        buffs[index] = 255;
        timers[index] = 0;
    end
    for _, entry in ipairs(entries) do
        buffs[entry[1]] = entry[2];
        timers[entry[1]] = raw_timer(entry[3] or 0);
    end
    return buffs, timers;
end

local function view(entries)
    local buffs, timers = arrays(entries);
    return maneuverview.from_arrays(buffs, timers, {
        now = now,
        utcstamp = utc,
    });
end

local function equal(actual, expected, label)
    assert(actual == expected, ('%s: expected %s, got %s'):format(
        label, tostring(expected), tostring(actual)));
end

-- Duplicate elements retain independent server timers and are ordered by the
-- next actual expiration, not by a locally inferred activation queue.
local initial = view({
    { 3, 307, 42 }, -- Dark
    { 8, 305, 51 }, -- Water
    { 11, 307, 58 }, -- Dark
});
equal(initial.counts.Dark, 2, 'duplicate Dark count');
equal(initial.counts.Water, 1, 'Water count');
equal(initial.oldest.name, 'Dark', 'oldest element');
equal(initial.oldest.remaining, 42, 'oldest remaining');
equal(#initial.maneuvers, 3, 'initial total');

-- Ashita can briefly publish the incoming fourth maneuver before clearing the
-- outgoing oldest slot. The reader must expose the post-replacement set in the
-- same frame instead of allowing consumers to render or plan around four.
local replacement = view({
    { 2, 300, 12 }, -- outgoing Fire
    { 5, 301, 31 }, -- Ice
    { 8, 302, 47 }, -- Wind
    { 12, 303, 60 }, -- incoming Earth
});
equal(replacement.raw_maneuver_count, 4, 'replacement raw total');
equal(replacement.trimmed_maneuver_count, 1, 'replacement trimmed total');
equal(#replacement.maneuvers, 3, 'replacement active total');
equal(replacement.counts.Fire, nil, 'replacement removed oldest');
equal(replacement.counts.Earth, 1, 'replacement retained incoming');
equal(replacement.oldest.name, 'Ice', 'replacement next expiry');

-- Economizer behavior requires no action-specific mutation: Ashita's next
-- snapshot simply contains no Dark instances.
local economizer = view({ { 8, 305, 50 } });
equal(economizer.counts.Dark, nil, 'Economizer removed all Dark');
equal(economizer.counts.Water, 1, 'Economizer preserved Water');
equal(#economizer.maneuvers, 1, 'Economizer total');

-- Flame Holder behavior is likewise represented by one fewer Fire slot.
local before_ws = view({
    { 2, 300, 35 },
    { 5, 300, 48 },
    { 9, 302, 55 },
});
local after_ws = view({
    { 5, 300, 47 },
    { 9, 302, 54 },
});
equal(before_ws.counts.Fire, 2, 'pre-WS Fire count');
equal(after_ws.counts.Fire, 1, 'Flame Holder removed one Fire');
equal(after_ws.counts.Wind, 1, 'Flame Holder preserved Wind');

-- Overload is authoritative from the same character buff array.
local overloaded = view({ { 1, 299, 10 } });
equal(overloaded.overloaded, true, 'Overload presence');
equal(#overloaded.maneuvers, 0, 'Overload maneuver total');

-- Implausible raw timers never become a false "stable" claim.
local invalid_timer = view({ { 4, 301, 600 } });
equal(invalid_timer.counts.Ice, 1, 'invalid-timer membership');
equal(invalid_timer.oldest.remaining, nil, 'invalid timer rejected');
equal(invalid_timer.oldest.approximate, true, 'invalid timer marked');

print('maneuverview tests passed');
