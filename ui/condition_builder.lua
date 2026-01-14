-- =========================================================================
-- ui/condition_builder.lua - Condition Builder for SideKick abilities
-- =========================================================================
-- Ported from Medley's condition builder for use with AAs, Discs, and Items

local mq = require('mq')
local imgui = require('ImGui')

local M = {}

-- Dependencies (set via init)
local _Core = nil

-- Local cache to prevent repeated initialization flicker
local _conditionCache = {}

-- Track edit mode per condition group (true = editing, false = viewing)
local _editMode = {}

-- Debug logging (disabled by default)
local _debugEnabled = false

local function debugLog(fmt, ...)
  if not _debugEnabled then return end
  local msg = string.format(fmt, ...)
  print(string.format('\ay[CondBuilder]\ax %s', msg))
end

--- Enable or disable debug logging
function M.setDebug(enabled)
  _debugEnabled = enabled
end

--- Initialize the condition builder module with dependencies
function M.init(opts)
  opts = opts or {}
  _Core = opts.Core
end

--- Clear cached condition data for a specific key (or all if no key provided)
function M.clearCache(uniqueId)
  if uniqueId then
    _conditionCache[uniqueId] = nil
  else
    _conditionCache = {}
  end
end

-- =========================================================================
-- Natural Language Definitions
-- =========================================================================

-- Subject dropdown: combines type + subject into natural language
-- value format: "type:subject" for easy parsing
M.subjectOptions = {
  { value = "beneficial:Me",     label = "My" },
  { value = "beneficial:Group",  label = "My Group's" },
  { value = "detrimental:Target", label = "My Target" },
  { value = "spawn:Spawn",       label = "There are" },
}

-- Properties for each subject (with natural labels)
-- type = "negated" means it displays as "is not X" with no operator combo (always checks for false/nil)
M.properties = {
  ["beneficial:Me"] = {
    { key = "PctHPs",       label = "HP",         type = "numeric", isPercent = true, min = 0, max = 100 },
    { key = "PctMana",      label = "Mana",       type = "numeric", isPercent = true, min = 0, max = 100 },
    { key = "PctEndurance", label = "Endurance",  type = "numeric", isPercent = true, min = 0, max = 100 },
    { key = "Invis",        label = "Invisibility", type = "boolean" },
    { key = "Combat",       label = "In Combat",  type = "boolean" },
    { key = "PctAggro",     label = "Aggro %",    type = "numeric", isPercent = true, min = 0, max = 100 },
    { key = "SecondaryPctAggro", label = "Secondary Aggro %", type = "numeric", isPercent = true, min = 0, max = 100 },
    { key = "XTargetHaterCount", label = "XTarget Haters", type = "numeric", min = 0, max = 20 },
    { key = "XTargetHasMezzed", label = "XTarget Has Mezzed Mob", type = "boolean" },
  },
  ["beneficial:Group"] = {
    { key = "Injured", label = "members w/ HP below", type = "group", thresholdLabel = "%", min = 0, max = 6, thresholdMin = 1, thresholdMax = 99 },
    { key = "LowMana", label = "members w/ Mana below", type = "group", thresholdLabel = "%", min = 0, max = 6, thresholdMin = 1, thresholdMax = 99 },
  },
  ["detrimental:Target"] = {
    { key = "PctHPs",   label = "HP",       type = "numeric", isPercent = true, min = 0, max = 100 },
    { key = "Level",    label = "Level",    type = "numeric", min = 1, max = 125 },
    { key = "Distance", label = "Distance", type = "numeric", min = 0, max = 500 },
    { key = "Named",    label = "Is a Named",    type = "affirmed" },
    { key = "Slowed",   label = "is not Slowed",   type = "negated" },
    { key = "Rooted",   label = "is not Rooted",   type = "negated" },
    { key = "Mezzed",   label = "is not Mezzed",   type = "negated" },
    { key = "Snared",   label = "is not Snared",   type = "negated" },
  },
  ["spawn:Spawn"] = {
    { key = "SpawnCount", label = "Spawns", type = "spawn", min = 1, max = 50, thresholdMin = 10, thresholdMax = 300 },
  },
}

-- Natural language operators for numeric comparisons
M.numericOperators = {
  { value = "<",  label = "is below" },
  { value = ">",  label = "is above" },
  { value = "<=", label = "is at most" },
  { value = ">=", label = "is at least" },
  { value = "==", label = "equals" },
  { value = "><", label = "is between" },
}

-- Natural language operators for boolean
M.booleanOperators = {
  { value = "true",  label = "is active" },
  { value = "false", label = "is not active" },
}

-- Logic connectors
M.logicOptions = {
  { value = "AND", label = "AND" },
  { value = "OR",  label = "OR" },
}

-- =========================================================================
-- Helper Functions
-- =========================================================================

--- Parse combined subject value into type and subject
local function parseSubjectValue(combined)
  local t, s = combined:match("^(%w+):(%w+)$")
  return t or "beneficial", s or "Me"
end

--- Get combined subject value from type and subject
local function getCombinedSubject(condType, subject)
  return (condType or "beneficial") .. ":" .. (subject or "Me")
end

--- Get properties for a combined subject value
local function getPropsForCombined(combined)
  return M.properties[combined] or M.properties["beneficial:Me"]
end

--- Find property definition by key
local function findProp(props, key)
  for _, p in ipairs(props) do
    if p.key == key then return p end
  end
  return nil
end

--- Create a new empty condition
local function newCondition()
  return {
    type = "beneficial",
    subject = "Me",
    property = "PctHPs",
    operator = "<",
    value = 50,
    threshold = nil,
  }
end

--- Create a new empty condition group
function M.newConditionGroup()
  return {
    conditions = { newCondition() },
    logic = {},
  }
end

-- =========================================================================
-- ImGui Label Builders
-- =========================================================================

local function buildSubjectLabels()
  local labels = {}
  for _, s in ipairs(M.subjectOptions) do
    table.insert(labels, s.label)
  end
  return table.concat(labels, '\0') .. '\0\0'
end

local function buildPropertyLabels(props)
  local labels = {}
  for _, p in ipairs(props) do
    table.insert(labels, p.label)
  end
  return table.concat(labels, '\0') .. '\0\0'
end

local function buildOperatorLabels(isBoolean)
  local ops = isBoolean and M.booleanOperators or M.numericOperators
  local labels = {}
  for _, o in ipairs(ops) do
    table.insert(labels, o.label)
  end
  return table.concat(labels, '\0') .. '\0\0'
end

local function buildLogicLabels()
  local labels = {}
  for _, l in ipairs(M.logicOptions) do
    table.insert(labels, l.label)
  end
  return table.concat(labels, '\0') .. '\0\0'
end

-- Cached labels
local _subjectLabels = buildSubjectLabels()
local _logicLabels = buildLogicLabels()

-- Helper to calculate combo width based on text + padding for dropdown arrow
local function calcComboWidth(text)
  local textWidth = imgui.CalcTextSize(text)
  return textWidth + 35  -- Add padding for dropdown arrow and right margin
end

-- Build readable string for a single condition
local function buildSingleConditionString(cond)
  local combined = getCombinedSubject(cond.type, cond.subject)
  local props = getPropsForCombined(combined)
  local propDef = findProp(props, cond.property)

  -- Subject label
  local subjectLabel = "?"
  for _, s in ipairs(M.subjectOptions) do
    if s.value == combined then subjectLabel = s.label break end
  end

  -- Property label
  local propLabel = propDef and propDef.label or cond.property
  local propType = propDef and propDef.type or "numeric"

  -- Handle negated type (e.g., "is not Rooted")
  if propType == "negated" then
    return "When " .. subjectLabel .. " " .. propLabel
  end

  -- Handle affirmed type (e.g., "Is a Named")
  if propType == "affirmed" then
    return "When " .. subjectLabel .. " " .. propLabel
  end

  -- Handle group type (e.g., "When My Group's members w/ HP below 50% >= 3")
  if propType == "group" then
    local threshold = cond.threshold or 50
    local str = "When " .. subjectLabel .. " " .. propLabel .. " " .. threshold .. "%"
    -- Operator
    local opLabel = cond.operator or ">="
    for _, o in ipairs(M.numericOperators) do
      if o.value == cond.operator then opLabel = o.label break end
    end
    str = str .. " " .. opLabel .. " " .. tostring(cond.value or 3)
    return str
  end

  -- Handle spawn type (e.g., "There are 3 or more Spawns within 50 range")
  if propType == "spawn" then
    local count = cond.value or 1
    local radius = cond.threshold or 50
    return "There are " .. count .. " or more " .. propLabel .. " within " .. radius .. " range"
  end

  -- Build string for numeric/boolean
  local str = "When " .. subjectLabel .. " " .. propLabel

  -- Operator
  local opLabel = cond.operator
  local ops = (propType == "boolean") and M.booleanOperators or M.numericOperators
  for _, o in ipairs(ops) do
    if o.value == cond.operator then opLabel = o.label break end
  end
  str = str .. " " .. opLabel

  -- Value (numeric only)
  if propType ~= "boolean" then
    str = str .. " " .. tostring(cond.value or 0)
    if propDef and propDef.isPercent then
      str = str .. "%"
    end
    -- Handle "between" operator
    if cond.operator == "><" then
      str = str .. " and " .. tostring(cond.value2 or 100)
      if propDef and propDef.isPercent then
        str = str .. "%"
      end
    end
  end

  return str
end

-- =========================================================================
-- Drawing Functions
-- =========================================================================

--- Draw a single condition row with natural language (edit mode with auto-sized combos)
local function drawConditionRowEdit(condition, index, uniqueId)
  local changed = false
  local deleted = false

  imgui.PushID(uniqueId .. '_cond_' .. index)

  -- Check if this is a spawn type condition
  local combined = getCombinedSubject(condition.type, condition.subject)
  local isSpawnType = combined == "spawn:Spawn"

  -- Static "When" prefix (skip for spawn type)
  if not isSpawnType then
    imgui.TextColored(0.7, 0.7, 0.7, 1.0, "When")
    imgui.SameLine()
  end

  -- Subject combo (My / My Group's / My Target / There are)
  local subjectIdx = 1
  local currentSubjectLabel = "My"
  for i, s in ipairs(M.subjectOptions) do
    if s.value == combined then
      subjectIdx = i
      currentSubjectLabel = s.label
      break
    end
  end

  -- Auto-size subject combo
  imgui.PushItemWidth(calcComboWidth(currentSubjectLabel))
  local newSubjectIdx = imgui.Combo("##subject", subjectIdx, _subjectLabels)
  if newSubjectIdx ~= subjectIdx then
    local newCombined = M.subjectOptions[newSubjectIdx].value
    local newType, newSubject = parseSubjectValue(newCombined)
    condition.type = newType
    condition.subject = newSubject
    -- Reset property to first valid option
    local props = getPropsForCombined(newCombined)
    condition.property = props[1] and props[1].key or ""
    condition.threshold = nil
    -- Reset operator based on new property type
    local propDef = findProp(props, condition.property)
    if propDef and propDef.type == "boolean" then
      condition.operator = "true"
    elseif propDef and propDef.type == "negated" then
      condition.operator = "false"
    elseif propDef and propDef.type == "affirmed" then
      condition.operator = "true"
    elseif propDef and propDef.type == "group" then
      condition.operator = ">="
      condition.value = 3  -- Default to 3 members
      condition.threshold = 50  -- Default to 50%
    else
      condition.operator = "<"
    end
    changed = true
    -- Update spawn type flag after subject change
    isSpawnType = newCombined == "spawn:Spawn"
  end
  imgui.PopItemWidth()

  -- Skip property combo for spawn type (only has one option)
  combined = getCombinedSubject(condition.type, condition.subject)
  local props = getPropsForCombined(combined)
  local propIdx = 1
  local currentPropLabel = "HP"
  for i, p in ipairs(props) do
    if p.key == condition.property then
      propIdx = i
      currentPropLabel = p.label
      break
    end
  end

  -- Only show property combo if not spawn type
  if not isSpawnType then
    imgui.SameLine()

    -- Auto-size property combo
    imgui.PushItemWidth(calcComboWidth(currentPropLabel))
    local propLabels = buildPropertyLabels(props)
    local newPropIdx = imgui.Combo("##property", propIdx, propLabels)
    if newPropIdx ~= propIdx then
      condition.property = props[newPropIdx].key
      condition.threshold = nil
      -- Reset operator based on new property type
      local propDef = findProp(props, condition.property)
      if propDef and propDef.type == "boolean" then
        condition.operator = "true"
      elseif propDef and propDef.type == "negated" then
        condition.operator = "false"
      elseif propDef and propDef.type == "affirmed" then
        condition.operator = "true"
      elseif propDef and propDef.type == "group" then
        condition.operator = ">="
        condition.value = 3  -- Default to 3 members
        condition.threshold = 50  -- Default to 50%
      else
        condition.operator = "<"
      end
      changed = true
    end
    imgui.PopItemWidth()
  end

  -- Get current property definition
  local propDef = findProp(props, condition.property)
  local propType = propDef and propDef.type or "numeric"

  -- Handle "negated" type (e.g., "is not Rooted") - no operator combo needed
  if propType == "negated" then
    imgui.SameLine()
    imgui.PushStyleColor(ImGuiCol.Button, 0.6, 0.2, 0.2, 1.0)
    imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0.8, 0.3, 0.3, 1.0)
    if imgui.SmallButton("X##delete") then
      deleted = true
    end
    imgui.PopStyleColor(2)
    imgui.PopID()
    return changed, deleted
  end

  -- Handle "affirmed" type (e.g., "Is a Named") - no operator combo needed
  if propType == "affirmed" then
    imgui.SameLine()
    imgui.PushStyleColor(ImGuiCol.Button, 0.6, 0.2, 0.2, 1.0)
    imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0.8, 0.3, 0.3, 1.0)
    if imgui.SmallButton("X##delete") then
      deleted = true
    end
    imgui.PopStyleColor(2)
    imgui.PopID()
    return changed, deleted
  end

  -- Handle "group" type (threshold % first, then operator, then count value)
  if propType == "group" then
    imgui.SameLine()
    imgui.PushItemWidth(30)
    local threshold = condition.threshold or 50
    local newThreshold = imgui.InputInt("##threshold", threshold, 0, 0)
    if newThreshold ~= threshold then
      local tMin = propDef.thresholdMin or 1
      local tMax = propDef.thresholdMax or 99
      condition.threshold = math.max(tMin, math.min(tMax, newThreshold))
      changed = true
    end
    imgui.PopItemWidth()
    imgui.SameLine(0, 1)
    imgui.TextColored(0.7, 0.7, 0.7, 1.0, "%")

    -- Operator combo for group
    imgui.SameLine()
    local ops = M.numericOperators
    local opIdx = 1
    local currentOpLabel = "is at least"
    for i, o in ipairs(ops) do
      if o.value == condition.operator then
        opIdx = i
        currentOpLabel = o.label
        break
      end
    end
    imgui.PushItemWidth(calcComboWidth(currentOpLabel))
    local opLabels = buildOperatorLabels(false)
    local newOpIdx = imgui.Combo("##operator", opIdx, opLabels)
    if newOpIdx ~= opIdx then
      condition.operator = ops[newOpIdx].value
      changed = true
    end
    imgui.PopItemWidth()

    -- Value input (count of members)
    imgui.SameLine()
    imgui.PushItemWidth(30)
    local value = condition.value or 3
    local newValue = imgui.InputInt("##value", value, 0, 0)
    if newValue ~= value then
      local vMin = propDef.min or 0
      local vMax = propDef.max or 6
      condition.value = math.max(vMin, math.min(vMax, newValue))
      changed = true
    end
    imgui.PopItemWidth()

    -- Delete button
    imgui.SameLine()
    imgui.PushStyleColor(ImGuiCol.Button, 0.6, 0.2, 0.2, 1.0)
    imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0.8, 0.3, 0.3, 1.0)
    if imgui.SmallButton("X##delete") then
      deleted = true
    end
    imgui.PopStyleColor(2)
    imgui.PopID()
    return changed, deleted
  end

  -- Handle "spawn" type (e.g., "There are 3 or more Spawns within 50 range")
  if propType == "spawn" then
    -- Count input
    imgui.SameLine()
    imgui.PushItemWidth(30)
    local count = condition.value or 1
    local newCount = imgui.InputInt("##count", count, 0, 0)
    if newCount ~= count then
      local vMin = propDef.min or 1
      local vMax = propDef.max or 50
      condition.value = math.max(vMin, math.min(vMax, newCount))
      changed = true
    end
    imgui.PopItemWidth()

    imgui.SameLine()
    imgui.TextColored(0.7, 0.7, 0.7, 1.0, "or more")

    -- Property dropdown (Spawns)
    imgui.SameLine()
    imgui.PushItemWidth(calcComboWidth(currentPropLabel))
    local propLabels = buildPropertyLabels(props)
    local newPropIdx = imgui.Combo("##property", propIdx, propLabels)
    if newPropIdx ~= propIdx then
      condition.property = props[newPropIdx].key
      changed = true
    end
    imgui.PopItemWidth()

    imgui.SameLine()
    imgui.TextColored(0.7, 0.7, 0.7, 1.0, "within")

    -- Range input
    imgui.SameLine()
    imgui.PushItemWidth(35)
    local radius = condition.threshold or 50
    local newRadius = imgui.InputInt("##radius", radius, 0, 0)
    if newRadius ~= radius then
      local rMin = propDef.thresholdMin or 10
      local rMax = propDef.thresholdMax or 300
      condition.threshold = math.max(rMin, math.min(rMax, newRadius))
      changed = true
    end
    imgui.PopItemWidth()

    imgui.SameLine(0, 1)
    imgui.TextColored(0.7, 0.7, 0.7, 1.0, "range")

    -- Delete button
    imgui.SameLine()
    imgui.PushStyleColor(ImGuiCol.Button, 0.6, 0.2, 0.2, 1.0)
    imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0.8, 0.3, 0.3, 1.0)
    if imgui.SmallButton("X##delete") then
      deleted = true
    end
    imgui.PopStyleColor(2)
    imgui.PopID()
    return changed, deleted
  end

  imgui.SameLine()

  -- Operator combo
  local isBoolean = propType == "boolean"
  local ops = isBoolean and M.booleanOperators or M.numericOperators
  local opIdx = 1
  local currentOpLabel = "is below"
  for i, o in ipairs(ops) do
    if o.value == condition.operator then
      opIdx = i
      currentOpLabel = o.label
      break
    end
  end

  -- Auto-size operator combo
  imgui.PushItemWidth(calcComboWidth(currentOpLabel))
  local opLabels = buildOperatorLabels(isBoolean)
  local newOpIdx = imgui.Combo("##operator", opIdx, opLabels)
  if newOpIdx ~= opIdx then
    condition.operator = ops[newOpIdx].value
    changed = true
  end
  imgui.PopItemWidth()

  -- Value input (only for numeric)
  if not isBoolean then
    imgui.SameLine()
    imgui.PushItemWidth(30)
    local value = condition.value or 0
    local newValue = imgui.InputInt("##value", value, 0, 0)
    if newValue ~= value then
      local vMin = propDef and propDef.min or 0
      local vMax = propDef and propDef.max or 100
      condition.value = math.max(vMin, math.min(vMax, newValue))
      changed = true
    end
    imgui.PopItemWidth()

    -- Append % for percentage values
    local isPercent = propDef and propDef.isPercent
    if isPercent then
      imgui.SameLine(0, 1)
      imgui.TextColored(0.7, 0.7, 0.7, 1.0, "%")
    end

    -- Handle "between" operator - add second value input
    if condition.operator == "><" then
      imgui.SameLine()
      imgui.TextColored(0.7, 0.7, 0.7, 1.0, "and")
      imgui.SameLine()
      imgui.PushItemWidth(30)
      local value2 = condition.value2 or 100
      local newValue2 = imgui.InputInt("##value2", value2, 0, 0)
      if newValue2 ~= value2 then
        local vMin = propDef and propDef.min or 0
        local vMax = propDef and propDef.max or 100
        condition.value2 = math.max(vMin, math.min(vMax, newValue2))
        changed = true
      end
      imgui.PopItemWidth()
      if isPercent then
        imgui.SameLine(0, 1)
        imgui.TextColored(0.7, 0.7, 0.7, 1.0, "%")
      end
    end
  end

  -- Delete button
  imgui.SameLine()
  imgui.PushStyleColor(ImGuiCol.Button, 0.6, 0.2, 0.2, 1.0)
  imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0.8, 0.3, 0.3, 1.0)
  if imgui.SmallButton("X##delete") then
    deleted = true
  end
  imgui.PopStyleColor(2)

  imgui.PopID()

  return changed, deleted
end

--- Draw a single condition row in view mode (read-only label)
local function drawConditionRowView(condition, index, uniqueId)
  imgui.PushID(uniqueId .. '_cond_view_' .. index)

  local condStr = buildSingleConditionString(condition)
  imgui.TextColored(0.8, 0.9, 1.0, 1.0, condStr)

  imgui.PopID()
end

--- Draw logic connector between conditions
local function drawLogicConnector(logicArray, index, uniqueId)
  local changed = false

  imgui.PushID(uniqueId .. '_logic_' .. index)

  local currentLogic = logicArray[index] or "AND"
  local logicIdx = 1
  for i, l in ipairs(M.logicOptions) do
    if l.value == currentLogic then logicIdx = i break end
  end

  imgui.SetCursorPosX(imgui.GetCursorPosX() + 40)
  imgui.PushItemWidth(55)
  local newLogicIdx = imgui.Combo("##logic", logicIdx, _logicLabels)
  if newLogicIdx ~= logicIdx then
    logicArray[index] = M.logicOptions[newLogicIdx].value
    changed = true
  end
  imgui.PopItemWidth()

  imgui.PopID()

  return changed
end

--- Draw the inline condition builder for an ability
function M.drawInline(uniqueId, conditionData, onChange)
  -- Use cached data if available
  if _conditionCache[uniqueId] then
    conditionData = _conditionCache[uniqueId]
  elseif conditionData and conditionData.conditions and #conditionData.conditions > 0 then
    _conditionCache[uniqueId] = conditionData
  end

  -- Initialize with default if nil
  local wasNil = not conditionData or not conditionData.conditions or #conditionData.conditions == 0
  if wasNil then
    conditionData = M.newConditionGroup()
    _conditionCache[uniqueId] = conditionData
    _editMode[uniqueId] = true  -- Start in edit mode for new conditions
  end

  -- Default to view mode if not set (for existing conditions)
  if _editMode[uniqueId] == nil then
    _editMode[uniqueId] = false
  end

  local isEditing = _editMode[uniqueId]
  local anyChanged = wasNil
  local indicesToDelete = {}

  -- Edit/Set toggle button
  if isEditing then
    -- In edit mode: show Set button (green)
    imgui.PushStyleColor(ImGuiCol.Button, 0.2, 0.5, 0.2, 1.0)
    imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0.3, 0.6, 0.3, 1.0)
    if imgui.SmallButton("Set##" .. uniqueId) then
      _editMode[uniqueId] = false
    end
    imgui.PopStyleColor(2)

    imgui.SameLine()

    -- Add button (only in edit mode)
    if imgui.SmallButton("[+]##" .. uniqueId) then
      table.insert(conditionData.conditions, newCondition())
      table.insert(conditionData.logic, "AND")
      anyChanged = true
    end
    if imgui.IsItemHovered() then
      imgui.SetTooltip("Add Condition")
    end
  else
    -- In view mode: show Edit button (blue)
    imgui.PushStyleColor(ImGuiCol.Button, 0.2, 0.3, 0.5, 1.0)
    imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0.3, 0.4, 0.6, 1.0)
    if imgui.SmallButton("Edit##" .. uniqueId) then
      _editMode[uniqueId] = true
    end
    imgui.PopStyleColor(2)
  end

  -- Draw conditions based on mode
  if isEditing then
    -- Edit mode: show combos and inputs
    for i, cond in ipairs(conditionData.conditions) do
      local changed, deleted = drawConditionRowEdit(cond, i, uniqueId)
      if changed then
        anyChanged = true
      end
      if deleted then
        table.insert(indicesToDelete, i)
      end

      -- Draw logic connector between conditions
      if i < #conditionData.conditions then
        if drawLogicConnector(conditionData.logic, i, uniqueId) then
          anyChanged = true
        end
      end
    end

    -- Process deletions (in reverse to maintain indices)
    for i = #indicesToDelete, 1, -1 do
      local idx = indicesToDelete[i]
      table.remove(conditionData.conditions, idx)
      if idx > 1 then
        table.remove(conditionData.logic, idx - 1)
      elseif #conditionData.logic > 0 then
        table.remove(conditionData.logic, 1)
      end
      anyChanged = true
    end

    -- Ensure at least one condition exists
    if #conditionData.conditions == 0 then
      conditionData = M.newConditionGroup()
      _conditionCache[uniqueId] = conditionData
      anyChanged = true
    end
  else
    -- View mode: show read-only labels
    imgui.SameLine()
    for i, cond in ipairs(conditionData.conditions) do
      if i > 1 then
        -- Show logic connector as text
        local logic = conditionData.logic[i - 1] or "AND"
        imgui.SameLine()
        imgui.TextColored(0.6, 0.6, 0.6, 1.0, logic)
        imgui.SameLine()
      end
      drawConditionRowView(cond, i, uniqueId)
      -- Keep conditions on same line if possible
      if i < #conditionData.conditions then
        imgui.SameLine()
      end
    end
  end

  -- Update cache and callback if changed
  if anyChanged then
    _conditionCache[uniqueId] = conditionData
    if onChange then
      onChange(conditionData)
    end
  end

  return conditionData
end

--- Build a human-readable preview string
function M.buildPreviewString(conditionData)
  if not conditionData or not conditionData.conditions or #conditionData.conditions == 0 then
    return "(none)"
  end

  local parts = {}
  for i, cond in ipairs(conditionData.conditions) do
    table.insert(parts, buildSingleConditionString(cond))
    if i < #conditionData.conditions then
      local logic = conditionData.logic[i] or "AND"
      table.insert(parts, logic)
    end
  end

  return table.concat(parts, " ")
end

-- =========================================================================
-- Runtime Evaluation
-- =========================================================================

--- Evaluate a single condition
local function evaluateSingleCondition(cond)
  local combined = getCombinedSubject(cond.type, cond.subject)
  local props = getPropsForCombined(combined)
  local propDef = findProp(props, cond.property)
  if not propDef then return false end

  local propType = propDef.type
  local value = nil

  if cond.type == "detrimental" then
    local Target = mq.TLO.Target
    if not Target() then return false end

    -- Handle "negated" type (is not Rooted, etc.) - check for nil/empty
    if propType == "negated" then
      local raw = Target[cond.property]()
      return raw == nil or raw == '' or raw == false
    -- Handle "affirmed" type (Is a Named) - check for true
    elseif propType == "affirmed" then
      local raw = Target[cond.property]()
      return raw == true
    elseif propType == "boolean" then
      local raw = Target[cond.property]()
      if cond.property == "Named" then
        value = raw == true
      else
        value = raw ~= nil and raw ~= ''
      end
    else
      value = Target[cond.property]()
    end

  elseif cond.type == "beneficial" then
    if cond.subject == "Me" then
      -- Try to get values from runtime cache first (more efficient)
      local ok, Cache = pcall(require, 'utils.runtime_cache')
      if ok and Cache and Cache.me then
        if cond.property == 'PctAggro' then
          value = Cache.me.pctAggro or 0
        elseif cond.property == 'SecondaryPctAggro' then
          value = Cache.me.secondaryPctAggro or 0
        elseif cond.property == 'XTargetHaterCount' then
          value = Cache.xtarget.count or 0
        elseif cond.property == 'XTargetHasMezzed' then
          -- Check CC module for mezzed mobs on XTarget
          local ccOk, CC = pcall(require, 'automation.cc')
          if ccOk and CC and CC.hasAnyMezzedOnXTarget then
            value = CC.hasAnyMezzedOnXTarget()
          else
            value = Cache.hasAnyMezzedOnXTarget and Cache.hasAnyMezzedOnXTarget() or false
          end
        end
      end

      -- Fall back to direct TLO access if not from cache
      if value == nil then
        local Me = mq.TLO.Me
        if propType == "boolean" then
          value = Me[cond.property]() == true
        else
          value = Me[cond.property]() or 0
        end
      end

    elseif cond.subject == "Group" then
      -- Group type: Group.Injured(threshold)() returns count of members below threshold%
      local Group = mq.TLO.Group
      local threshold = cond.threshold or 50
      value = Group[cond.property](threshold)() or 0
    end

  elseif cond.type == "spawn" then
    if cond.property == "SpawnCount" then
      local radius = cond.threshold or 50
      local count = mq.TLO.SpawnCount('npc radius ' .. radius .. ' targetable')() or 0
      local requiredCount = tonumber(cond.value) or 1
      return count >= requiredCount
    end
  end

  if value == nil then return false end

  -- Evaluate based on property type and operator
  if propType == "boolean" then
    if cond.operator == "true" then
      return value == true
    else
      return value == false
    end
  else
    local numValue = tonumber(value) or 0
    local compareValue = tonumber(cond.value) or 0

    if cond.operator == ">" then return numValue > compareValue
    elseif cond.operator == "<" then return numValue < compareValue
    elseif cond.operator == ">=" then return numValue >= compareValue
    elseif cond.operator == "<=" then return numValue <= compareValue
    elseif cond.operator == "==" then return numValue == compareValue
    elseif cond.operator == "><" then
      -- Between operator
      local compareValue2 = tonumber(cond.value2) or 100
      return numValue >= compareValue and numValue <= compareValue2
    end
  end

  return false
end

--- Evaluate a condition group
function M.evaluate(conditionData)
  if not conditionData or not conditionData.conditions or #conditionData.conditions == 0 then
    return true  -- No conditions = always pass
  end

  local result = evaluateSingleCondition(conditionData.conditions[1])

  for i = 2, #conditionData.conditions do
    local logic = conditionData.logic[i - 1] or "AND"
    local condResult = evaluateSingleCondition(conditionData.conditions[i])

    if logic == "AND" then
      result = result and condResult
    else
      result = result or condResult
    end
  end

  return result
end

--- Evaluate a condition with explicit context (pure function, no global state)
-- @param conditionData table The condition data structure
-- @param ctx table Context with targetId, targetHp, targetClass, myHp, myMana, etc.
-- @return boolean True if condition passes
function M.evaluateWithContext(conditionData, ctx)
  if not conditionData or not conditionData.conditions or #conditionData.conditions == 0 then
    return true  -- No conditions = always pass
  end

  ctx = ctx or {}

  local function evaluateSingle(cond)
    local combined = getCombinedSubject(cond.type, cond.subject)
    local props = getPropsForCombined(combined)
    local propDef = findProp(props, cond.property)
    local propType = propDef and propDef.type or "numeric"

    local actual = nil

    -- Resolve actual value based on type + subject + property
    if cond.type == "beneficial" then
      if cond.subject == "Me" then
        if cond.property == "PctHPs" then
          actual = ctx.myHp
          if actual == nil then actual = mq.TLO.Me.PctHPs() or 100 end
        elseif cond.property == "PctMana" then
          actual = ctx.myMana
          if actual == nil then actual = mq.TLO.Me.PctMana() or 100 end
        elseif cond.property == "PctEndurance" then
          actual = ctx.myEndurance
          if actual == nil then actual = mq.TLO.Me.PctEndurance() or 100 end
        elseif cond.property == "Combat" then
          actual = ctx.inCombat
          if actual == nil then actual = mq.TLO.Me.Combat() or false end
        elseif cond.property == "Invis" then
          actual = ctx.isInvis
          if actual == nil then actual = mq.TLO.Me.Invis() or false end
        elseif cond.property == "PctAggro" then
          actual = ctx.pctAggro
          if actual == nil then actual = mq.TLO.Me.PctAggro() or 0 end
        elseif cond.property == "SecondaryPctAggro" then
          actual = ctx.secondaryPctAggro
          if actual == nil then actual = mq.TLO.Me.SecondaryPctAggro() or 0 end
        elseif cond.property == "XTargetHaterCount" then
          actual = ctx.xtargetHaterCount
          if actual == nil then
            local count = 0
            for i = 1, 13 do
              local xtSpawn = mq.TLO.Me.XTarget(i)
              if xtSpawn() and xtSpawn.TargetType() == "Auto Hater" then
                count = count + 1
              end
            end
            actual = count
          end
        elseif cond.property == "XTargetHasMezzed" then
          actual = ctx.xtargetHasMezzed
          if actual == nil then actual = false end  -- Requires CC module, default to false
        end
      elseif cond.subject == "Group" then
        if cond.property == "Injured" then
          actual = ctx.groupInjuredCount
          if actual == nil then
            local threshold = cond.threshold or 50
            actual = mq.TLO.Group.Injured(threshold)() or 0
          end
        elseif cond.property == "LowMana" then
          actual = ctx.groupLowManaCount
          if actual == nil then
            local threshold = cond.threshold or 50
            actual = mq.TLO.Group.LowMana(threshold)() or 0
          end
        end
      end

    elseif cond.type == "detrimental" then
      -- Target-based conditions
      if cond.property == "PctHPs" then
        actual = ctx.targetHp
        if actual == nil and mq.TLO.Target() then
          actual = mq.TLO.Target.PctHPs()
        end
      elseif cond.property == "Level" then
        actual = ctx.targetLevel
        if actual == nil and mq.TLO.Target() then
          actual = mq.TLO.Target.Level()
        end
      elseif cond.property == "Distance" then
        actual = ctx.targetDistance
        if actual == nil and mq.TLO.Target() then
          actual = mq.TLO.Target.Distance()
        end
      elseif cond.property == "Named" then
        actual = ctx.targetNamed
        if actual == nil and mq.TLO.Target() then
          actual = mq.TLO.Target.Named() == true
        end
      elseif cond.property == "Slowed" then
        actual = ctx.targetSlowed
        if actual == nil and mq.TLO.Target() then
          local raw = mq.TLO.Target.Slowed()
          actual = raw ~= nil and raw ~= '' and raw ~= false
        end
      elseif cond.property == "Rooted" then
        actual = ctx.targetRooted
        if actual == nil and mq.TLO.Target() then
          local raw = mq.TLO.Target.Rooted()
          actual = raw ~= nil and raw ~= '' and raw ~= false
        end
      elseif cond.property == "Mezzed" then
        actual = ctx.targetMezzed
        if actual == nil and mq.TLO.Target() then
          local raw = mq.TLO.Target.Mezzed()
          actual = raw ~= nil and raw ~= '' and raw ~= false
        end
      elseif cond.property == "Snared" then
        actual = ctx.targetSnared
        if actual == nil and mq.TLO.Target() then
          local raw = mq.TLO.Target.Snared()
          actual = raw ~= nil and raw ~= '' and raw ~= false
        end
      end

    elseif cond.type == "spawn" then
      if cond.property == "SpawnCount" then
        actual = ctx.spawnCount
        if actual == nil then
          local radius = cond.threshold or 50
          actual = mq.TLO.SpawnCount('npc radius ' .. radius .. ' targetable')() or 0
        end
        local requiredCount = tonumber(cond.value) or 1
        return actual >= requiredCount
      end
    end

    -- Handle nil actual value
    if actual == nil then return false end

    -- Handle negated type (is not Rooted, etc.) - check for nil/empty/false
    if propType == "negated" then
      return actual == nil or actual == '' or actual == false
    end

    -- Handle affirmed type (Is a Named) - check for true
    if propType == "affirmed" then
      return actual == true
    end

    -- Evaluate based on property type and operator
    if propType == "boolean" then
      if cond.operator == "true" then
        return actual == true
      else
        return actual == false
      end
    elseif propType == "group" then
      -- Group type uses numeric comparison on count
      local numValue = tonumber(actual) or 0
      local compareValue = tonumber(cond.value) or 0
      if cond.operator == ">" then return numValue > compareValue
      elseif cond.operator == "<" then return numValue < compareValue
      elseif cond.operator == ">=" then return numValue >= compareValue
      elseif cond.operator == "<=" then return numValue <= compareValue
      elseif cond.operator == "==" then return numValue == compareValue
      elseif cond.operator == "><" then
        local compareValue2 = tonumber(cond.value2) or 100
        return numValue >= compareValue and numValue <= compareValue2
      end
    else
      -- Numeric comparison
      local numValue = tonumber(actual) or 0
      local compareValue = tonumber(cond.value) or 0

      if cond.operator == ">" then return numValue > compareValue
      elseif cond.operator == "<" then return numValue < compareValue
      elseif cond.operator == ">=" then return numValue >= compareValue
      elseif cond.operator == "<=" then return numValue <= compareValue
      elseif cond.operator == "==" then return numValue == compareValue
      elseif cond.operator == "><" then
        local compareValue2 = tonumber(cond.value2) or 100
        return numValue >= compareValue and numValue <= compareValue2
      end
    end

    return true  -- Unknown operator = pass
  end

  -- Evaluate first condition
  local result = evaluateSingle(conditionData.conditions[1])

  -- Apply connectors for subsequent conditions
  for i = 2, #conditionData.conditions do
    local logic = conditionData.logic[i - 1] or "AND"
    local condResult = evaluateSingle(conditionData.conditions[i])

    if logic == "AND" then
      result = result and condResult
    elseif logic == "OR" then
      result = result or condResult
    end
  end

  return result
end

-- =========================================================================
-- Serialization (for INI storage)
-- =========================================================================

function M.serialize(conditionData)
  if not conditionData then return "" end
  local ok, result = pcall(function()
    return mq.pickle("", conditionData)
  end)
  if ok and result then
    return result
  end
  return ""
end

function M.deserialize(str)
  if not str or str == "" then return nil end
  local fn, err = load("return " .. str, "condition", "t", {})
  if fn then
    local ok, data = pcall(fn)
    if ok and type(data) == "table" then
      return data
    end
  end
  return nil
end

return M
