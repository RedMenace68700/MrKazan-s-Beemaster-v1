-- Serializer for plain data: nil, booleans, numbers, strings and nested tables.
-- Shared by server, robot and PC tests, so it must not depend on OpenOS libraries.
-- The output is a Lua literal. Keys are sorted, so equal data gives equal text.

local serial = {}

local KEYWORDS = {}
for word in ([[and break do else elseif end false for function goto if in
  local nil not or repeat return then true until while]]):gmatch("%a+") do
  KEYWORDS[word] = true
end

local KEY_TYPE_ORDER = { number = 1, string = 2, boolean = 3 }

local function encode_number(n)
  if n ~= n then return "0/0" end
  if n == math.huge then return "1/0" end
  if n == -math.huge then return "-1/0" end
  if n == math.floor(n) and n >= -2 ^ 53 and n <= 2 ^ 53 then
    return string.format("%.0f", n)
  end
  return string.format("%.17g", n)
end

local function key_less(a, b)
  local ta, tb = type(a), type(b)
  if ta ~= tb then return KEY_TYPE_ORDER[ta] < KEY_TYPE_ORDER[tb] end
  if ta == "boolean" then return (not a) and b end
  return a < b
end

local encode

local function encode_key(key, out, seen)
  if type(key) == "string" and key:match("^[%a_][%w_]*$") and not KEYWORDS[key] then
    out[#out + 1] = key
  else
    out[#out + 1] = "["
    encode(key, out, seen)
    out[#out + 1] = "]"
  end
  out[#out + 1] = "="
end

encode = function(value, out, seen)
  local kind = type(value)
  if kind == "nil" then
    out[#out + 1] = "nil"
  elseif kind == "boolean" then
    out[#out + 1] = value and "true" or "false"
  elseif kind == "number" then
    out[#out + 1] = encode_number(value)
  elseif kind == "string" then
    out[#out + 1] = string.format("%q", value)
  elseif kind == "table" then
    if seen[value] then error("serial: cyclic table", 0) end
    seen[value] = true
    out[#out + 1] = "{"
    local first = true
    local count = 0
    while value[count + 1] ~= nil do
      count = count + 1
      if not first then out[#out + 1] = "," end
      first = false
      encode(value[count], out, seen)
    end
    local keys = {}
    for key in pairs(value) do
      local key_type = type(key)
      if not KEY_TYPE_ORDER[key_type] then
        error("serial: unsupported key type " .. key_type, 0)
      end
      local in_array = key_type == "number" and key >= 1 and key <= count and key == math.floor(key)
      if not in_array then keys[#keys + 1] = key end
    end
    table.sort(keys, key_less)
    for _, key in ipairs(keys) do
      if not first then out[#out + 1] = "," end
      first = false
      encode_key(key, out, seen)
      encode(value[key], out, seen)
    end
    out[#out + 1] = "}"
    seen[value] = nil
  else
    error("serial: unsupported type " .. kind, 0)
  end
end

-- Returns the data as a string. Raises an error for functions, cycles and similar.
function serial.encode(value)
  local out = {}
  encode(value, out, {})
  return table.concat(out)
end

-- Returns the data, or nil plus an error text. The text is evaluated without any
-- globals, so it cannot call library functions.
function serial.decode(text)
  if type(text) ~= "string" then return nil, "not a string" end
  local fn, err = load("return " .. text, "=data", "t", {})
  if not fn then return nil, err end
  local ok, result = pcall(fn)
  if not ok then return nil, result end
  return result
end

return serial
