-- Turns a failed robot reply into an error object with a readable message.

local errors = require("server.errors")
local bees = require("shared.bees")

local replies = {}

-- context (optional): at = position id, expected = text, command = robot command name
function replies.error(reply, context)
  context = context or {}
  local info = type(reply.info) == "table" and reply.info or {}
  local code = reply.err or "ROBOT_INTERNAL"
  local args
  if code == "ROBOT_TIMEOUT" or code == "ROBOT_RESTARTED" then
    args = { info.id, info.name }
  elseif code == "ROBOT_BLOCKED" then
    args = { info.reason or info.step }
  elseif code == "ROBOT_NO_INVENTORY" or code == "ROBOT_CHEST_FULL" then
    args = { context.at }
  elseif code == "ROBOT_EMPTY_SLOT" or code == "ROBOT_SLOT_BUSY" then
    args = { info.slot }
  elseif code == "ROBOT_MISMATCH" then
    args = { info.slot, bees.describe(info.found), context.expected }
  elseif code == "ROBOT_TRANSFER_FAILED" then
    args = { info.reason }
  elseif code == "ROBOT_INTERNAL" then
    args = { info.text }
  elseif code == "ROBOT_UNKNOWN_COMMAND" then
    args = { info.name }
  elseif code == "ROBOT_BAD_ARGS" then
    args = { context.command }
  elseif code == "ROBOT_COMPONENT_MISSING" then
    args = { info.name }
  elseif code == "ROBOT_STALE_ID" then
    args = { info.last }
  else
    args = {}
  end
  for i = 1, 3 do
    if args[i] == nil then args[i] = "?" end
  end
  return errors.new(code, args[1], args[2], args[3])
end

return replies
