-- The list of known species, read from species.txt.
-- Names are matched case-insensitively; lookup() returns the spelling from the file.

local species = {}

local Registry = {}
Registry.__index = Registry

local function clean(name)
  name = name:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
  return name
end

function species.from_list(list)
  local registry = setmetatable({ names = {}, by_key = {} }, Registry)
  for _, raw in ipairs(list) do
    local name = clean(raw)
    local key = name:lower()
    if name ~= "" and not registry.by_key[key] then
      registry.by_key[key] = name
      registry.names[#registry.names + 1] = name
    end
  end
  return registry
end

-- One name per line; empty lines and lines starting with '#' are ignored.
function species.parse_text(text)
  local list = {}
  for line in text:gmatch("[^\r\n]+") do
    local name = clean(line)
    if name ~= "" and name:sub(1, 1) ~= "#" then list[#list + 1] = name end
  end
  return species.from_list(list)
end

-- Returns the registry, or nil plus an error text.
function species.load(path)
  local file, err = io.open(path, "r")
  if not file then return nil, err end
  local text = file:read("*a")
  file:close()
  return species.parse_text(text or "")
end

-- Spelling from species.txt, or nil if the name is unknown.
function Registry:lookup(name)
  if type(name) ~= "string" then return nil end
  return self.by_key[clean(name):lower()]
end

function Registry:count()
  return #self.names
end

return species
