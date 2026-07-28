-- Compile every Lua file passed on the command line without executing it.

local failures = {}
local checked = 0

for index = 1, #arg do
    local path = tostring(arg[index] or '')
    if path ~= '' then
        checked = checked + 1
        local chunk, err = loadfile(path)
        if not chunk then
            failures[#failures + 1] = string.format('%s: %s', path, tostring(err))
        end
    end
end

print(string.format('lua_parse_test: %d files, %d failures', checked, #failures))
for _, failure in ipairs(failures) do print(failure) end

if #failures > 0 then os.exit(1) end
