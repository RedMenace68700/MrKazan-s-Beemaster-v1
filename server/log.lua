-- Log with time stamps. Every line goes to the log file (if a path is set), to an
-- optional echo function (e.g. the screen) and to a short in-memory history.

local log = {}

local Logger = {}
Logger.__index = Logger

local function default_clock()
  return os.date("%H:%M:%S")
end

-- opts: path, clock (function returning a time text), echo (function(line, level)),
--       history (number of lines kept in memory, default 50)
function log.new(opts)
  opts = opts or {}
  return setmetatable({
    path = opts.path,
    clock = opts.clock or default_clock,
    echo = opts.echo,
    max_history = opts.history or 50,
    history = {},
  }, Logger)
end

function Logger:write(level, text)
  local line = string.format("%s %-5s %s", self.clock(), level, text)
  self.history[#self.history + 1] = line
  if #self.history > self.max_history then table.remove(self.history, 1) end
  if self.path then
    local file = io.open(self.path, "a")
    if file then
      file:write(line, "\n")
      file:close()
    end
  end
  if self.echo then self.echo(line, level) end
  return line
end

function Logger:info(text) return self:write("INFO", text) end
function Logger:warn(text) return self:write("WARN", text) end
function Logger:error(text) return self:write("ERROR", text) end

-- Robot events carry the id of the command they belong to.
function Logger:event(id, text)
  return self:write("ROBOT", "#" .. tostring(id) .. " " .. text)
end

-- The last n lines (all kept lines if n is nil).
function Logger:recent(n)
  local first = n and math.max(1, #self.history - n + 1) or 1
  local lines = {}
  for i = first, #self.history do lines[#lines + 1] = self.history[i] end
  return lines
end

return log
