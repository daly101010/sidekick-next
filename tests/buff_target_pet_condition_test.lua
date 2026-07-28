package.preload['mq'] = function()
    return { TLO = {} }
end

package.preload['ImGui'] = function()
    return {}
end

local ConditionBuilder = dofile('ui/condition_builder.lua')

local function petCondition(operator)
    return {
        logic = 'AND',
        conditions = {
            {
                type = 'beneficial',
                subject = 'BuffTarget',
                property = 'IsPet',
                operator = operator,
            },
        },
    }
end

assert(ConditionBuilder.evaluateWithContext(
    petCondition('true'), { buffTargetIsPet = true }) == true)
assert(ConditionBuilder.evaluateWithContext(
    petCondition('true'), { buffTargetIsPet = false }) == false)
assert(ConditionBuilder.evaluateWithContext(
    petCondition('false'), { buffTargetIsPet = false }) == true)
assert(ConditionBuilder.evaluateWithContext(
    petCondition('false'), { buffTargetIsPet = true }) == false)

local petPropertyFound = false
for _, property in ipairs(
        ConditionBuilder.properties['beneficial:BuffTarget'] or {}) do
    if property.key == 'IsPet' and property.type == 'boolean' then
        petPropertyFound = true
        break
    end
end
assert(petPropertyFound, 'Buff Target is Pet is missing from the editor')

print('buff_target_pet_condition_test: ok')
