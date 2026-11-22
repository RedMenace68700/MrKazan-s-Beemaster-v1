-- Reads one line typed at the server terminal.
--
-- Results:
--   { kind = "empty" }
--   { kind = "request", a = "Clay", b = "Diligent", c = "Tin" }
--   { kind = "request", c = "Iron", count = 5 }               (typed as "= iron 5")
--   { kind = "command", name = "set", args = { "ResultMode", "extra_spares" } }
--   { kind = "error", code = "INPUT_FORMAT", msg = "[INPUT_FORMAT] ..." }

local errors = require("server.errors")

local parser = {}

-- Console commands, in the order 'help' lists them. 'help' prints one line per command,
-- so name and help text together must fit an 80 column screen (see console.lua).
parser.COMMANDS = {
  { name = "go", args = 0, help = "Start the queue, or continue after pause" },
  { name = "pause", args = 0, help = "Hold the robot before its next command" },
  { name = "stop", args = 0, help = "Abort: robot stores its bees, goes to the charger" },
  { name = "status", args = 0, help = "Request, step, queue, honey and robot" },
  { name = "queue", args = 0, help = "List the queued requests" },
  { name = "clear", args = 0, help = "Empty the queue (only while idle)" },
  { name = "settings", args = 0, max_args = 1, usage = "settings [<Setting>]",
    help = "Show settings and options; settings <Setting> explains one" },
  { name = "set", args = 2, usage = "set <Setting> <value>", help = "set <Setting> <value>, e.g. set QuestMode on" },
  { name = "setup", args = 0, help = "Check which chests and machines are present" },
  { name = "inventorysetup", args = 0, help = "Setup, then read every chest into the inventory" },
  { name = "scanall", args = 0, help = "Analyze all unanalyzed bees (1 honey per stack)" },
  { name = "selftest", args = 0, help = "Not available yet" },
  { name = "cycle", args = 4, usage = "cycle <pos> <slot> <pos> <slot>",
    help = "cycle <pos> <slot> <pos> <slot>: one test cycle" },
  { name = "dump", args = 2, usage = "dump <pos> <slot>", help = "dump <pos> <slot>: save slot data to dump.txt" },
  { name = "help", args = 0, help = "Show this list" },
  { name = "quit", args = 0, help = "End the server program (only while idle)" },
}

local COMMAND_BY_NAME = {}
for _, command in ipairs(parser.COMMANDS) do COMMAND_BY_NAME[command.name] = command end

local function trim(text)
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function fail(code, ...)
  local err = errors.new(code, ...)
  return { kind = "error", code = err.code, msg = err.msg }
end

parser.MAX_MULTIPLY = 1000

-- "= Iron 5": breed a pure Iron pair 5 times (count defaults to 1).
local function parse_multiply(line, registry)
  local rest = trim(line:sub(2))
  local name, count_text = rest:match("^(.-)%s+(%d+)$")
  if not name then name = rest end
  name = trim(name)
  if name == "" or name:find("[+=]") then return fail("INPUT_FORMAT", line) end
  local species = registry:lookup(name)
  if not species then return fail("INPUT_UNKNOWN_SPECIES", name) end
  local count = tonumber(count_text or "1")
  if count < 1 or count > parser.MAX_MULTIPLY then return fail("INPUT_COUNT", parser.MAX_MULTIPLY) end
  return { kind = "request", c = species, count = count }
end

local function parse_request(line, registry)
  local left, right = line:match("^([^=]*)=([^=]*)$")
  if not left then return fail("INPUT_FORMAT", line) end
  local a, b = left:match("^([^+]*)%+([^+]*)$")
  if not a or right:find("+", 1, true) then return fail("INPUT_FORMAT", line) end
  local raw = { trim(a), trim(b), trim(right) }
  local names = {}
  for i, name in ipairs(raw) do
    if name == "" then return fail("INPUT_FORMAT", line) end
    names[i] = registry:lookup(name)
    if not names[i] then return fail("INPUT_UNKNOWN_SPECIES", name) end
  end
  if names[3] == names[1] or names[3] == names[2] then
    return fail("INPUT_TARGET_IS_PARENT", names[3])
  end
  return { kind = "request", a = names[1], b = names[2], c = names[3] }
end

-- registry: species registry from server/species.lua
function parser.parse(line, registry)
  line = trim(line or "")
  if line == "" then return { kind = "empty" } end
  if line:sub(1, 1) == "=" then return parse_multiply(line, registry) end
  if line:find("[+=]") then return parse_request(line, registry) end

  local words = {}
  for word in line:gmatch("%S+") do words[#words + 1] = word end
  local command = COMMAND_BY_NAME[words[1]:lower()]
  if not command then return fail("INPUT_UNKNOWN_COMMAND", words[1]) end
  local args = { table.unpack(words, 2) }
  if #args < command.args or #args > (command.max_args or command.args) then
    return fail("INPUT_USAGE", command.usage or command.name)
  end
  return { kind = "command", name = command.name, args = args }
end

return parser
