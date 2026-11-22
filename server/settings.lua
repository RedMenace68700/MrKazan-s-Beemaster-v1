-- Player settings with defaults and validation.
-- Keys and enum values are matched case-insensitively; stored with the spelling below.

local errors = require("server.errors")

local settings = {}

settings.DEFINITIONS = {
  { key = "ResultMode", type = "enum", values = { "single_pair", "extra_spares" }, default = "single_pair",
    help = "single_pair: 1 pure princess + 1 pure drone; extra_spares: princess + SpareDrones pure drones" },
  { key = "SpareDrones", type = "int", min = 1, max = 64, default = 5,
    help = "Number of pure drones delivered in extra_spares mode" },
  { key = "PristineMode", type = "enum", values = { "PristineOnly", "AnyMode" }, default = "PristineOnly",
    help = "PristineOnly uses only bees with isNatural = true" },
  { key = "OnMissing", type = "enum", values = { "skip", "halt" }, default = "skip",
    help = "What to do when bees for a request are missing" },
  { key = "CycleTimeout", type = "int", min = 30, max = 3600, default = 300,
    help = "Seconds to wait for the offspring of one cycle" },
  { key = "MinFreeOutputSlots", type = "int", min = 1, max = 54, default = 8,
    help = "Stop when the output chest has fewer free slots" },
  { key = "MaxCyclesPerRequest", type = "int", min = 1, max = 1000, default = 40,
    help = "Give up a request after this many cycles" },
  { key = "MinHoney", type = "int", min = 1, max = 10000, default = 10,
    help = "Stop when fewer honey drops are left" },
  { key = "DroneSafetyMode", type = "bool", default = true,
    help = "The last pure drone of a species may only be paired with a pure princess of the same species" },
  { key = "AutoStocking", type = "bool", default = false,
    help = "Breed more drones of a parent species first when only one pure drone is left" },
  { key = "QuestMode", type = "bool", default = false,
    help = "Never take bees out of the provider chests" },
  { key = "TimeZone", type = "int", min = -12, max = 14, default = 0,
    help = "Hours to add to UTC for the times in the log, e.g. 1 for Central Europe" },
}

local BY_KEY = {}
for _, def in ipairs(settings.DEFINITIONS) do BY_KEY[def.key:lower()] = def end

local TRUE_WORDS = { ["true"] = true, on = true, yes = true, ["1"] = true }
local FALSE_WORDS = { ["false"] = true, off = true, no = true, ["0"] = true }

-- Returns the value in its proper type, or nil if it is not allowed.
local function coerce(def, raw)
  if def.type == "enum" then
    local text = tostring(raw):lower()
    for _, value in ipairs(def.values) do
      if value:lower() == text then return value end
    end
  elseif def.type == "int" then
    local n = tonumber(raw)
    if n and n == math.floor(n) and n >= def.min and n <= def.max then return math.floor(n) end
  elseif def.type == "bool" then
    if raw == true or raw == false then return raw end
    local text = tostring(raw):lower()
    if TRUE_WORDS[text] then return true end
    if FALSE_WORDS[text] then return false end
  end
  return nil
end

function settings.allowed_text(def)
  if def.type == "enum" then return table.concat(def.values, ", ") end
  if def.type == "int" then return def.min .. " to " .. def.max end
  return "on, off"
end

function settings.format_value(value)
  if value == true then return "on" end
  if value == false then return "off" end
  return tostring(value)
end

local Settings = {}
Settings.__index = Settings

-- saved: table from Settings:to_table(), or nil. Invalid saved values fall back to the
-- default and are listed in the returned object's warnings.
function settings.new(saved)
  local object = setmetatable({ values = {}, warnings = {} }, Settings)
  for _, def in ipairs(settings.DEFINITIONS) do
    local raw = saved and saved[def.key]
    local value = nil
    if raw ~= nil then
      value = coerce(def, raw)
      if value == nil then
        object.warnings[#object.warnings + 1] = errors.format("SETTING_BAD_VALUE", raw, def.key, settings.allowed_text(def))
      end
    end
    if value == nil then value = def.default end
    object.values[def.key] = value
  end
  return object
end

function Settings:get(key)
  local def = BY_KEY[tostring(key):lower()]
  if not def then error("unknown setting " .. tostring(key), 2) end
  return self.values[def.key]
end

-- Returns true, key, value or nil, error object.
function Settings:set(key, raw)
  local def = BY_KEY[tostring(key):lower()]
  if not def then return nil, errors.new("SETTING_UNKNOWN", key) end
  local value = coerce(def, raw)
  if value == nil then
    return nil, errors.new("SETTING_BAD_VALUE", raw, def.key, settings.allowed_text(def))
  end
  self.values[def.key] = value
  return true, def.key, value
end

-- List of { key, value, default, help } in definition order.
function Settings:entries()
  local list = {}
  for _, def in ipairs(settings.DEFINITIONS) do
    list[#list + 1] = { key = def.key, value = self.values[def.key], default = def.default, help = def.help,
                        definition = def }
  end
  return list
end

function Settings:to_table()
  local copy = {}
  for key, value in pairs(self.values) do copy[key] = value end
  return copy
end

return settings
