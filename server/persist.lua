-- Saves and loads plain tables as files. Works in OpenOS and with plain Lua on a PC.
--
-- A file is first written as <path>.tmp and then renamed, so a crash while writing
-- never leaves a half-written file behind. If only the .tmp file exists (crash between
-- delete and rename), load() uses it.

local serial = require("shared.serial")

local persist = {}

-- Returns true, or nil plus an error text.
function persist.save(path, data)
  local ok, text = pcall(serial.encode, data)
  if not ok then return nil, text end
  local tmp = path .. ".tmp"
  local file, err = io.open(tmp, "w")
  if not file then return nil, err end
  local written, werr = file:write(text, "\n")
  file:close()
  if not written then
    os.remove(tmp)
    return nil, werr
  end
  os.remove(path)
  local renamed, rerr = os.rename(tmp, path)
  if not renamed then return nil, rerr end
  return true
end

local function read_file(path)
  local file = io.open(path, "r")
  if not file then return nil end
  local text = file:read("*a")
  file:close()
  return text
end

-- Returns the data, or nil plus an error text ("not found" if there is no file).
function persist.load(path)
  local text = read_file(path) or read_file(path .. ".tmp")
  if not text then return nil, "not found" end
  local data, err = serial.decode(text)
  if data == nil then return nil, err or "empty file" end
  return data
end

return persist
