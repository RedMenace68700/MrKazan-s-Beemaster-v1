-- Small diagnostic tasks: robot status and dumping one chest slot.
-- Their results are shown without an alert (quiet = true).

local grid = require("shared.grid")
local serial = require("shared.serial")
local motion = require("server.motion")
local replies = require("server.replies")

local diag = {}

function diag.status(ctx)
  local reply = ctx.call("status")
  if not reply.ok then return { ok = false, error = replies.error(reply), quiet = true } end
  local d = reply.data
  local percent = d.max_energy and d.max_energy > 0 and math.floor(d.energy / d.max_energy * 100) or 0
  return {
    ok = true,
    quiet = true,
    lines = { string.format("Robot: %s, energy %d%%, %d/%d slots used, version %s",
      motion.describe(ctx.state.pos), percent, d.used or 0, d.slots or 0, tostring(d.version)) },
  }
end

-- Saves the full item data of one chest slot. write(text) stores it.
function diag.dump(ctx, id, slot, write)
  local ok, err = motion.go(ctx, grid.position(id))
  if not ok then return { ok = false, error = err, quiet = true } end
  local reply = ctx.call("dump", { slot = slot })
  local back, back_err = motion.home(ctx)
  if not reply.ok then return { ok = false, error = replies.error(reply, { at = id }), quiet = true } end
  if not back then return { ok = false, error = back_err, quiet = true } end
  if reply.data.stack == nil then
    return { ok = true, quiet = true, lines = { string.format("Slot %d of %s is empty", slot, id) } }
  end
  local text = serial.encode(reply.data.stack)
  write(string.format("-- %s slot %d\n%s\n", id, slot, text))
  return { ok = true, quiet = true, lines = { string.format("Slot %d of %s saved (%d bytes)", slot, id, #text) } }
end

return diag
