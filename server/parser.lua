-- Reads one line typed at the server terminal.
--
-- Results:
--   { kind = "empty" }
--   { kind = "request", a = "Clay", b = "Diligent", c = "Tin" }
--   { kind = "command", name = "set", args = { "ResultMode", "extra_spares" } }
--   { kind = "error", code = "INPUT_FORMAT", msg = "[INPUT_FORMAT] ..." }

local errors = require("server.errors")

local parser = {}

-- Console commands, in the order 'help' lists them.
parser.COMMANDS = {
  { name = "go", args = 0, help = "Start or continue working on the queue" },
  { name = "stop", args = 0, help = "Finish the current step, tidy up and return home" },
  { name = "status", args = 0, help = "Show the current request, step and robot state" },
  { name = "queue", args = 0, help = "List the queued requests" },
  { name = "clear", args = 0, help = "Remove all queued requests (not while one is running)" },
  { name = "settings", args = 0, help = "Show all settings" },
  { name = "set", args = 2, usage = "set <Setting> <value>", help = "Change a setting, e.g. set ResultMode extra_spares" },
  { name = "setup", args = 0, help = "Let the robot check which chests and machines are present" },
  { name = "inventorysetup", args = 0, help = "Run setup and scan every chest into the inventory" },
  { name = "selftest", args = 0, help = "Let the robot test reachability without changing anything" },
  { name = "dump", args = 2, usage = "dump <position> <slot>", help = "Save the full data of one chest slot to data/dump.txt, e.g. dump 5/1 3" },
  { name = "help", args = 0, help = "Show this list" },
  { name = "quit", args = 0, help = "Stop the server program" },
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
  if line:find("[+=]") then return parse_request(line, registry) end

  local words = {}
  for word in line:gmatch("%S+") do words[#words + 1] = word end
  local command = COMMAND_BY_NAME[words[1]:lower()]
  if not command then return fail("INPUT_UNKNOWN_COMMAND", words[1]) end
  local args = { table.unpack(words, 2) }
  if #args ~= command.args then
    return fail("INPUT_USAGE", command.usage or command.name)
  end
  return { kind = "command", name = command.name, args = args }
end

return parser
