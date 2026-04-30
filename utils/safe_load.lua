--- Safe loading helpers for SideKick-owned serialized data files.
--- Compiles Lua table literals with an empty environment so persisted config
--- cannot execute with access to globals.

local M = {}

local function compile(src, chunkName)
    if type(load) == 'function' then
        local ok, fnOrErr = pcall(load, src, chunkName or 'data', 't', {})
        if ok and type(fnOrErr) == 'function' then
            return fnOrErr
        end
        if ok then return nil, fnOrErr end
    end

    if type(loadstring) == 'function' then
        local fn, err = loadstring(src, chunkName or 'data')
        if not fn then return nil, err end
        if type(setfenv) == 'function' then
            setfenv(fn, {})
        end
        return fn
    end

    return nil, 'no Lua loader available'
end

function M.tableLiteral(content, chunkName)
    if type(content) ~= 'string' or content == '' then
        return nil, 'empty content'
    end
    local trimmed = content:match('^%s*(.-)%s*$') or content
    local src = trimmed:match('^return%s+') and trimmed or ('return ' .. trimmed)
    local fn, err = compile(src, chunkName)
    if not fn then return nil, err end
    local ok, data = pcall(fn)
    if not ok then return nil, data end
    if type(data) ~= 'table' then return nil, 'loaded value is not a table' end
    return data
end

return M
