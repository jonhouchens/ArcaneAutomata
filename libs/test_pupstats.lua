package.path = './?.lua;' .. package.path

local pupstats = require('pupstats')

local function equal(actual, expected, label)
    assert(actual == expected, ('%s: expected %s, got %s'):format(
        label, tostring(expected), tostring(actual)))
end

local function packet(job, is_subjob)
    local bytes = {}
    for index = 1, 0x9C do bytes[index] = 0 end
    bytes[0x04 + 1] = job
    bytes[0x05 + 1] = is_subjob
    bytes[0x08 + 1] = 1
    bytes[0x09 + 1] = 20

    local function set_u16(offset, value)
        bytes[offset + 1] = value % 256
        bytes[offset + 2] = math.floor(value / 256)
    end

    for _, offset in ipairs({ 0x80, 0x84, 0x88, 0x8C, 0x90, 0x94, 0x98 }) do
        set_u16(offset, 40 + offset)
        set_u16(offset + 2, 5)
    end
    return string.char(unpack(bytes))
end

local stats = pupstats.new({ now = function() return 100 end })
equal(stats:on_job_info(packet(18, 0)), true, 'main-job PUP packet')
equal(stats.automaton_frame, 20, 'main-job frame parsed')

stats:clear()
equal(stats:on_job_info(packet(18, 1)), true, 'subjob-PUP packet')
equal(stats.pet_total[pupstats.STAT.STR], 173, 'subjob pet STR parsed')

stats:clear()
equal(stats:on_job_info(packet(18, 2)), false, 'invalid subjob flag rejected')
equal(stats:on_job_info(packet(17, 1)), false, 'non-PUP packet rejected')

print('pupstats tests passed')
