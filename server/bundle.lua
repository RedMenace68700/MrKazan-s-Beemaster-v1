-- Builds the robot program: robot/main.lua and the shared modules it uses, joined into
-- one chunk with a small require function, because the robot runs without OpenOS.

local bundle = {}

bundle.MODULES = { "shared.serial", "shared.protocol", "shared.bees", "shared.grid", "robot.main" }

local PRELUDE = [[
local __preload, __loaded = {}, {}
local function require(name)
  local value = __loaded[name]
  if value == nil then
    local loader = __preload[name]
    if not loader then error("module not found: " .. name, 2) end
    value = loader(name)
    if value == nil then value = true end
    __loaded[name] = value
  end
  return value
end
]]

local function read_file(path)
  local file, err = io.open(path, "r")
  if not file then return nil, err end
  local text = file:read("*a")
  file:close()
  return text
end

-- root: install directory. Returns the program text, or nil plus an error text.
function bundle.build(root, read)
  read = read or read_file
  local out = { PRELUDE }
  for _, name in ipairs(bundle.MODULES) do
    local path = root .. "/" .. name:gsub("%.", "/") .. ".lua"
    local text, err = read(path)
    if not text then return nil, path .. ": " .. tostring(err) end
    out[#out + 1] = string.format("__preload[%q] = function(...)\n", name)
    out[#out + 1] = text
    out[#out + 1] = "\nend\n"
  end
  out[#out + 1] = 'return require("robot.main").main(...)\n'
  return table.concat(out)
end

return bundle
