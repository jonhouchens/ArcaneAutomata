--[[
burdenforecast.lua (v1.1) -- shared action-aware burden projections

This presentation-neutral helper keeps PUPMan and Arcane Automata aligned on
one question: "what is the overload risk if this maneuver is used now?"
Colors and rendering remain addon-specific.
]]

local lib = {}
lib.VERSION = '1.1'

lib.RISK = {
    UNKNOWN = 'UNKNOWN',
    SAFE = 'SAFE',
    LOW = 'LOW',
    WARM = 'WARM',
    DANGER = 'DANGER',
    OVERLOAD = 'OVERLOAD',
}

function lib.classify(score, overloaded)
    if overloaded then return lib.RISK.OVERLOAD end
    if score == nil then return lib.RISK.UNKNOWN end
    if score == 0 then return lib.RISK.SAFE end
    if score >= 50 then return lib.RISK.DANGER end
    if score >= 20 then return lib.RISK.WARM end
    return lib.RISK.LOW
end

function lib.predict(model, element_index, overloaded)
    local result = {
        element = element_index,
        label = lib.classify(nil, overloaded),
        score = overloaded and 100 or nil,
        score_upper = overloaded and 100 or nil,
        quality = nil,
        gauge = nil,
        gain = nil,
        safe_seconds = nil,
        safe_seconds_upper = nil,
    }
    if overloaded or model == nil or element_index == nil then
        return result
    end

    model:tick()
    result.gauge, result.quality = model:get(element_index)
    if result.gauge == nil then return result end

    -- Resolve the stat-sensitive gain exactly once and pass it back into the
    -- model so every consumer forecasts from one coherent gear snapshot.
    result.gain = model:estimated_gain(element_index)
    result.score = model:chance_after_maneuver(element_index, result.gain)
    result.score_upper = result.score
    if result.quality == 'estimate' then
        local upper_gauge = result.gauge + model:decay_per_tick()
        result.score_upper = model:chance_for_gauge(upper_gauge + result.gain)
    end
    result.label = lib.classify(result.score, false)

    -- A zero-risk roll requires the pre-action gauge to be no higher than the
    -- threshold minus the gain applied before Horizon makes the overload roll.
    local safe_target = model:threshold() - result.gain
    if safe_target >= 0 then
        result.safe_seconds = model:seconds_to(element_index, safe_target)
        result.safe_seconds_upper = result.safe_seconds
        if result.quality == 'estimate' then
            result.safe_seconds_upper = model:seconds_to(
                element_index, safe_target - model:decay_per_tick())
        end
    end
    return result
end

return lib
