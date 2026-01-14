-- Test script for sk_spells_clr.lua enumeration
-- Run with: /lua run sidekick/test_spell_enum
local mq = require('mq')
local Spells = require('sidekick.sk_spells_clr')

local lines = Spells.enumerateLines()
print(string.format('Found %d spell lines', #lines))

for i, line in ipairs(lines) do
    if i <= 10 then
        print(string.format('  %s.%s (%s) - %d spells',
            line.category, line.lineName, line.defaultSlotType, #line.spells))
    end
end

-- Show remaining count if more than 10
if #lines > 10 then
    print(string.format('  ... and %d more spell lines', #lines - 10))
end

-- Test getLine function
local remedyLine = Spells.getLine('Remedy')
if remedyLine then
    print(string.format('\ngetLine("Remedy") found: %s.%s with %d spells',
        remedyLine.category, remedyLine.lineName, #remedyLine.spells))
else
    print('\ngetLine("Remedy") returned nil - ERROR!')
end

-- Count by slot type
local rotationCount = 0
local buffSwapCount = 0
for _, line in ipairs(lines) do
    if line.defaultSlotType == 'rotation' then
        rotationCount = rotationCount + 1
    elseif line.defaultSlotType == 'buff_swap' then
        buffSwapCount = buffSwapCount + 1
    end
end
print(string.format('\nSlot type summary: %d rotation, %d buff_swap', rotationCount, buffSwapCount))

print('\nEnumeration test complete')
