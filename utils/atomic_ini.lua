-- Staged INI persistence with validation and a retained last-known-good backup.

local lip = require('LIP')

local M = {}

local function hasData(value)
    if type(value) ~= 'table' then return false end
    for _ in pairs(value) do return true end
    return false
end

local function loadOne(path)
    local ok, value = pcall(lip.load, path)
    if ok and hasData(value) then return value end
    return nil
end

local function readAll(path)
    local file = io.open(path, 'rb')
    if not file then return nil end
    local content = file:read('*a')
    file:close()
    return content
end

local function writeAll(path, content)
    local file, err = io.open(path, 'w+b')
    if not file then return false, err end
    local ok, writeErr = pcall(function()
        file:write(content)
        file:flush()
    end)
    file:close()
    if not ok then return false, writeErr end
    return true
end

function M.load(path)
    local value = loadOne(path)
    if value then return value, path end
    local backup = loadOne(path .. '.bak')
    if backup then return backup, path .. '.bak' end
    return {}, nil
end

function M.save(path, value)
    local stage = path .. '.stage'
    pcall(os.remove, stage)

    local ok, result = pcall(lip.save, stage, value)
    if not ok or result == false then
        pcall(os.remove, stage)
        return false, tostring(result)
    end

    if not loadOne(stage) then
        pcall(os.remove, stage)
        return false, 'staged INI failed validation'
    end

    local stagedContent = readAll(stage)
    if not stagedContent then
        pcall(os.remove, stage)
        return false, 'unable to read validated stage'
    end

    -- Windows does not allow renaming a file while a worker briefly has it
    -- open for reading. Copy the old bytes to the backup, then install the
    -- validated bytes in place. There is still only one writer.
    local backup = path .. '.bak'
    local previousContent = readAll(path)
    if previousContent and #previousContent > 0 then
        local backupOk, backupErr = writeAll(backup, previousContent)
        if not backupOk then
            pcall(os.remove, stage)
            return false, 'backup failed: ' .. tostring(backupErr)
        end
    end

    local installed, installErr = writeAll(path, stagedContent)
    if not installed then
        pcall(os.remove, stage)
        return false, tostring(installErr)
    end
    pcall(os.remove, stage)

    if not loadOne(path) then
        if previousContent then writeAll(path, previousContent) end
        return false, 'installed INI failed validation'
    end
    return true
end

return M
