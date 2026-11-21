-- Installs or updates beemasterv1 from GitHub. Needs an internet card.
--   wget -f https://raw.githubusercontent.com/RedMenace68700/MrKazan-s-Beemaster-v1/main/install.lua /tmp/install.lua
--   /tmp/install.lua
-- Later updates: /home/beemasterv1/install.lua

local component = require("component")
local filesystem = require("filesystem")

local REPO = "https://raw.githubusercontent.com/RedMenace68700/MrKazan-s-Beemaster-v1/main/"
local ROOT = "/home/beemasterv1/"
local LAUNCHER = "/home/bin/beemasterv1.lua"
local SHRC = "/home/.shrc"

local FILES = {
  "install.lua",
  "bin/beemasterv1.lua",
  "robot/loader.lua",
  "robot/main.lua",
  "server/bundle.lua",
  "server/config.lua",
  "server/console.lua",
  "server/errors.lua",
  "server/layout.lua",
  "server/ledger.lua",
  "server/link.lua",
  "server/log.lua",
  "server/main.lua",
  "server/motion.lua",
  "server/parser.lua",
  "server/persist.lua",
  "server/queue.lua",
  "server/replies.lua",
  "server/runner.lua",
  "server/settings.lua",
  "server/species.lua",
  "server/species.txt",
  "server/terminal.lua",
  "server/tasks/diag.lua",
  "server/tasks/setup.lua",
  "shared/bees.lua",
  "shared/grid.lua",
  "shared/protocol.lua",
  "shared/serial.lua",
}

-- Files the player edits: only installed when they do not exist yet.
local KEEP = { ["server/species.txt"] = true }

if not component.isAvailable("internet") then
  io.stderr:write("beemasterv1 needs an internet card to install.\n")
  return 1
end
local internet = require("internet")

local function download(url)
  local ok, result = pcall(function()
    local parts = {}
    for chunk in internet.request(url) do parts[#parts + 1] = chunk end
    return table.concat(parts)
  end)
  if not ok then return nil, tostring(result) end
  if result == "" or result:sub(1, 3) == "404" then return nil, "not found" end
  return result
end

local function write(path, text)
  filesystem.makeDirectory(filesystem.path(path))
  local file, err = io.open(path, "wb")
  if not file then return nil, err end
  file:write(text)
  file:close()
  return true
end

print("Installing beemasterv1 into " .. ROOT)
local failed = 0
for _, name in ipairs(FILES) do
  local target = ROOT .. name
  if KEEP[name] and filesystem.exists(target) then
    print("  kept      " .. name)
  else
    local text, err = download(REPO .. name)
    local ok, werr = false, err
    if text then ok, werr = write(target, text) end
    if ok then
      print("  installed " .. name)
    else
      failed = failed + 1
      print("  FAILED    " .. name .. ": " .. tostring(werr))
    end
  end
end
if failed > 0 then
  io.stderr:write(failed .. " file(s) failed, please run the installer again.\n")
  return 1
end

filesystem.makeDirectory(filesystem.path(LAUNCHER))
filesystem.remove(LAUNCHER)
filesystem.copy(ROOT .. "bin/beemasterv1.lua", LAUNCHER)

local function has_autostart()
  local file = io.open(SHRC, "r")
  if not file then return false end
  for line in file:lines() do
    if line:match("^%s*beemasterv1%s*$") then
      file:close()
      return true
    end
  end
  file:close()
  return false
end

if not has_autostart() then
  io.write("Start beemasterv1 automatically when the computer boots? [y/N] ")
  local answer = io.read()
  if answer and answer:lower():sub(1, 1) == "y" then
    local file = io.open(SHRC, "a")
    if file then
      file:write("beemasterv1\n")
      file:close()
    end
  end
end

print("Done. Start the server with: beemasterv1")
print("Robot EEPROM: flash -q " .. ROOT .. "robot/loader.lua beemasterv1")
return 0
