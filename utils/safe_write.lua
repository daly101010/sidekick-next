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
    -- Write to temp file inside pcall to catch disk errors
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
    -- On Windows, os.rename fails if target exists — remove first
    os.remove(path)
    local renameOk, renameErr = os.rename(tmpPath, path)
    if not renameOk then
        pcall(os.remove, tmpPath)
        return false, tostring(renameErr)
    end
    return true
end

return safeWrite
