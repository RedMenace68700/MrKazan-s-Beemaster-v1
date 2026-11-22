-- Handles one line typed at the server terminal.
--
-- Commands that only touch the queue or the settings are carried out here. Commands
-- that need the robot or the run state are handed back to the main loop as an action.
--
-- ctx = { species = registry, queue = Queue, settings = Settings,
--         busy = function() return true while a request is running end }
-- Returns { lines = { text, ... }, action = "go" | ..., changed = "queue" | "settings",
--           error = code }

local parser = require("server.parser")
local queue = require("server.queue")
local errors = require("server.errors")
local settings = require("server.settings")

local console = {}

console.PROMPT = "Please input your desired requests (e.g. Clay + Diligent = Tin), 'help' for commands"

local ACTIONS = {
  go = true, pause = true, stop = true, status = true, setup = true,
  inventorysetup = true, scanall = true, selftest = true, cycle = true, dump = true, quit = true,
}

local function show_queue(ctx)
  local entries = ctx.queue:list()
  if #entries == 0 then return { "Queue is empty" } end
  local lines = {}
  for i, entry in ipairs(entries) do
    lines[i] = string.format("%2d. #%d %s", i, entry.id, queue.describe(entry))
  end
  return lines
end

-- Every setting with its value and the allowed values; one line each, fits 80 columns.
local function show_settings(ctx)
  local lines = { string.format("%-19s %-14s %s", "Setting", "Value", "Options") }
  for _, entry in ipairs(ctx.settings:entries()) do
    local value = settings.format_value(entry.value)
    if entry.value ~= entry.default then value = value .. " *" end
    lines[#lines + 1] = string.format("%-19s %-14s %s", entry.key, value, settings.allowed_text(entry.definition))
  end
  lines[#lines + 1] = "* = changed. Change: set <Setting> <value>. Explain: settings <Setting>"
  return lines
end

-- Splits a text into lines of at most `width` characters at spaces.
local function wrap(text, width)
  local lines, line = {}, ""
  for word in text:gmatch("%S+") do
    if line ~= "" and #line + 1 + #word > width then
      lines[#lines + 1] = line
      line = word
    else
      line = (line == "" and word) or (line .. " " .. word)
    end
  end
  if line ~= "" then lines[#lines + 1] = line end
  return lines
end

-- One setting explained: value, default, options and what it does.
local function explain_setting(ctx, key)
  for _, entry in ipairs(ctx.settings:entries()) do
    if entry.key:lower() == key:lower() then
      local lines = {
        string.format("%s = %s (default %s)", entry.key, settings.format_value(entry.value),
          settings.format_value(entry.default)),
        "Options: " .. settings.allowed_text(entry.definition),
      }
      for _, line in ipairs(wrap(entry.help, 78)) do lines[#lines + 1] = line end
      lines[#lines + 1] = "Change it with: set " .. entry.key .. " <value>"
      return lines
    end
  end
  return nil
end

local function show_help()
  local lines = { string.format("%-15s %s", "A + B = C", "Add a request, e.g. clay + diligent = tin") }
  for _, command in ipairs(parser.COMMANDS) do
    lines[#lines + 1] = string.format("%-15s %s", command.name, command.help)
  end
  return lines
end

function console.handle(ctx, line)
  local parsed = parser.parse(line, ctx.species)
  if parsed.kind == "empty" then return { lines = {} } end
  if parsed.kind == "error" then return { lines = { parsed.msg }, error = parsed.code } end

  if parsed.kind == "request" then
    local entry = ctx.queue:add(parsed)
    return {
      lines = { string.format("Queued #%d: %s", entry.id, queue.describe(entry)) },
      changed = "queue",
    }
  end

  local name = parsed.name
  if ACTIONS[name] then return { lines = {}, action = name, args = parsed.args } end

  if name == "queue" then
    return { lines = show_queue(ctx) }
  elseif name == "clear" then
    if ctx.busy and ctx.busy() then
      local err = errors.new("QUEUE_BUSY", "clear the queue")
      return { lines = { err.msg }, error = err.code }
    end
    local count = ctx.queue:clear()
    return { lines = { string.format("Removed %d request(s)", count) }, changed = "queue" }
  elseif name == "settings" and parsed.args[1] then
    local lines = explain_setting(ctx, parsed.args[1])
    if not lines then
      local err = errors.new("SETTING_UNKNOWN", parsed.args[1])
      return { lines = { err.msg }, error = err.code }
    end
    return { lines = lines }
  elseif name == "settings" then
    return { lines = show_settings(ctx) }
  elseif name == "set" then
    local ok, key, value = ctx.settings:set(parsed.args[1], parsed.args[2])
    if not ok then return { lines = { key.msg }, error = key.code } end
    return { lines = { key .. " = " .. settings.format_value(value) }, changed = "settings" }
  elseif name == "help" then
    return { lines = show_help() }
  end
  error("console: unhandled command " .. name)
end

return console
