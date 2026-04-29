--- Safe file write utility: write to temp then rename for crash safety.
--- Prevents truncated/corrupt files if write fails mid-stream.
---
--- Usage:
---   local safeWrite = require('sidekick-next.utils.safe_write')
---   local ok, err = safeWrite(path, content)

--- Write content to path via temp file + rename.
--- @param path string Target file path
--- @param content string Content to write
--- @return boolean ok
--- @return string|nil err Error message on failure
local function safeWrite(path, content)
    local tmpPath = path .. '.tmp'
    local bakPath = path .. '.bak'

    local ok, writeErr = pcall(function()
        local f, openErr = io.open(tmpPath, 'w')
        if not f then error(openErr or 'failed to open temp file') end
        f:write(content)
        f:close()
    end)
    if not ok then
        pcall(os.remove, tmpPath)
        return false, tostring(writeErr)
    end

    pcall(os.remove, bakPath)
    local hadExisting = false
    do
        local existing = io.open(path, 'r')
        if existing then
            existing:close()
            hadExisting = true
        end
    end

    if hadExisting then
        local bakOk, bakErr = os.rename(path, bakPath)
        if not bakOk then
            pcall(os.remove, tmpPath)
            return false, tostring(bakErr)
        end
    end

    local renameOk, renameErr = os.rename(tmpPath, path)
    if not renameOk then
        if hadExisting then
            pcall(os.rename, bakPath, path)
        end
        pcall(os.remove, tmpPath)
        return false, tostring(renameErr)
    end

    if hadExisting then
        pcall(os.remove, bakPath)
    end
    return true
end

return safeWrite
