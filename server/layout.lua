-- Turns the results of 'setup' into the layout the server works with.
--
-- During setup the robot visits every position from shared/grid.lua and reports the
-- inventory size it finds there. Positions without an inventory are left out.
-- Supply chests and the upper provider chests are optional; provider chest 2/1,
-- honey chest, apiary and output chest are required.

local grid = require("shared.grid")
local errors = require("server.errors")

local layout = {}

local ROLE_NAMES = {
  provider = "provider chest",
  supply = "supply chest",
  honey = "honey chest",
  apiary = "industrial apiary",
  output = "output chest",
}

function layout.describe(position)
  return string.format("%s at field %d, height %d", ROLE_NAMES[position.role] or position.role,
    position.field, position.height)
end

-- probes: map position id -> { size = n } for every position where an inventory was found.
-- Returns the layout and a list of error messages for missing required components
-- (empty list = setup succeeded).
--   layout = { chests = { [id] = { role, size } }, providers = { ids }, supplies = { ids },
--              honey = id, apiary = id, output = id }
function layout.evaluate(probes)
  local result = { chests = {}, providers = {}, supplies = {} }
  local problems = {}
  for _, position in ipairs(grid.positions()) do
    local probe = probes[position.id]
    if probe and (probe.size or 0) > 0 then
      result.chests[position.id] = { role = position.role, size = probe.size }
      if position.role == "provider" then
        result.providers[#result.providers + 1] = position.id
      elseif position.role == "supply" then
        result.supplies[#result.supplies + 1] = position.id
      else
        result[position.role] = position.id
      end
    elseif position.required then
      problems[#problems + 1] = errors.format("SETUP_MISSING", layout.describe(position))
    end
  end
  return result, problems
end

local function copy(list)
  local out = {}
  for i, value in ipairs(list) do out[i] = value end
  return out
end

-- Chests the robot may take bees from, in search order: supply chests first, then the
-- provider chests unless QuestMode forbids them.
function layout.source_order(lay, quest_mode)
  local order = copy(lay.supplies)
  if not quest_mode then
    for _, id in ipairs(lay.providers) do order[#order + 1] = id end
  end
  return order
end

-- Chests for leftover bees: supply chests only, field by field, bottom up.
function layout.store_order(lay)
  return copy(lay.supplies)
end

-- Chests for delivered results: provider chests bottom up. The next one is used only
-- when the one below is full.
function layout.deliver_order(lay)
  return copy(lay.providers)
end

return layout
