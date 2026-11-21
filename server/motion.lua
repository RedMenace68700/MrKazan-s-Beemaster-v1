-- Moving the robot around the grid and keeping track of where it is.
--
-- The server knows the robot's grid position (ctx.state.pos = { x, y, h, facing }).
-- After every move the navigation upgrade reports the real world position; together
-- with the world position of home (ctx.state.home, recorded by setup) this gives the
-- true grid position. Without a navigation position the server counts the steps.

local grid = require("shared.grid")
local errors = require("server.errors")
local replies = require("server.replies")

local motion = {}

-- Grid position from a navigation reading, or nil. Grid west (+x) is world -X,
-- grid north (+y) is world -Z.
function motion.from_world(home, nav)
  if not (home and type(nav) == "table" and nav.x and nav.y and nav.z) then return nil end
  return {
    x = 2 + home.x - nav.x,
    y = 2 + home.z - nav.z,
    h = 1 + nav.y - home.y,
    facing = grid.direction_of_side(nav.facing),
  }
end

-- Position after the first count steps.
function motion.apply(pos, steps, count)
  local p = { x = pos.x, y = pos.y, h = pos.h, facing = pos.facing }
  for i = 1, count do
    local step = steps[i]
    if step == "up" then
      p.h = p.h + 1
    elseif step == "down" then
      p.h = p.h - 1
    else
      local d = grid.DIRECTIONS[step]
      p.x, p.y, p.facing = p.x + d.dx, p.y + d.dy, step
    end
  end
  return p
end

function motion.describe(pos)
  if not pos then return "unknown position" end
  if pos.x >= 1 and pos.x <= grid.COLUMNS and pos.y >= 1 and pos.y <= grid.ROWS then
    return string.format("field %d height %d", grid.cell_to_field(pos.x, pos.y), pos.h)
  end
  return string.format("cell %d,%d height %d", pos.x, pos.y, pos.h)
end

local function same_place(a, b)
  return a.x == b.x and a.y == b.y and a.h == b.h
end

local function on_grid(p)
  return grid.is_walkable(p.x, p.y) and p.h >= 1 and p.h <= grid.MAX_HEIGHT
end

-- Moves the robot in front of target ({ x, y, h or height, facing }; facing optional).
-- Returns true, or nil plus an error object. ctx.state.pos is always updated.
function motion.go(ctx, target)
  local pos = ctx.state.pos
  local wanted = { x = target.x, y = target.y, h = target.h or target.height or 1 }
  local steps = grid.route(pos, wanted)
  if not steps then
    return nil, errors.new("ROBOT_LOST", motion.describe(pos), motion.describe(wanted))
  end
  if #steps == 0 and (not target.facing or target.facing == pos.facing) then return true end

  local reply = ctx.call("move", { steps = steps, face = target.facing })
  local info = type(reply.info) == "table" and reply.info or {}
  local done = reply.ok and #steps or info.done or 0
  local counted = motion.apply(pos, steps, done)
  if reply.ok and target.facing then counted.facing = target.facing end

  local nav = (reply.ok and reply.data and reply.data.nav) or info.nav
  local measured = motion.from_world(ctx.state.home, nav)
  if measured then
    ctx.state.pos = measured
    if not on_grid(measured) then
      return nil, errors.new("ROBOT_LOST", motion.describe(measured), motion.describe(counted))
    end
  else
    ctx.state.pos = counted
  end

  if not reply.ok then return nil, replies.error(reply, { command = "move" }) end
  if not same_place(ctx.state.pos, wanted) then
    return nil, errors.new("ROBOT_LOST", motion.describe(ctx.state.pos), motion.describe(wanted))
  end
  return true
end

function motion.home(ctx)
  return motion.go(ctx, grid.HOME)
end

return motion
