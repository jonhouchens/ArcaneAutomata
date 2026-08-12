-- Minimal FFXI action-packet parser.
-- Adapted from the MIT-licensed parser shipped with tTimers.
-- See THIRD_PARTY_NOTICES.md for attribution and license details.

local exports = {};

function exports.parse(e)
    local data = e.data_raw;
    local offset = 40;

    local function unpack_bits(length)
        local value = ashita.bits.unpack_be(data, 0, offset, length);
        offset = offset + length;
        return value;
    end

    local packet = T{};
    packet.UserId = unpack_bits(32);
    local target_count = unpack_bits(6);
    offset = offset + 4;
    packet.Type = unpack_bits(4);
    packet.Id = unpack_bits(17);
    offset = offset + 15;
    packet.Recast = unpack_bits(32);
    packet.Targets = T{};

    for _ = 1, target_count do
        local target = T{};
        target.Id = unpack_bits(32);
        local action_count = unpack_bits(4);
        target.Actions = T{};

        for _ = 1, action_count do
            local action = {};
            action.Reaction = unpack_bits(5);
            action.Animation = unpack_bits(12);
            action.SpecialEffect = unpack_bits(7);
            action.Knockback = unpack_bits(3);
            action.Param = unpack_bits(17);
            action.Message = unpack_bits(10);
            action.Flags = unpack_bits(31);

            if (unpack_bits(1) == 1) then
                action.AdditionalEffect = {
                    Damage = unpack_bits(10),
                    Param = unpack_bits(17),
                    Message = unpack_bits(10),
                };
            end

            if (unpack_bits(1) == 1) then
                action.SpikesEffect = {
                    Damage = unpack_bits(10),
                    Param = unpack_bits(14),
                    Message = unpack_bits(10),
                };
            end

            target.Actions:append(action);
        end

        packet.Targets:append(target);
    end

    return packet;
end

return exports;
