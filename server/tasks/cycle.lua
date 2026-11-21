-- 'cycle': one breeding cycle with a princess and a drone from given chest slots.
-- A test of the apiary mechanics before the planner chooses pairs on its own:
-- clear the output chest, take both bees, put them into the apiary, wait for the
-- offspring, collect and analyze them, store everything in the supply chests, go home.

local bees = require("shared.bees")
local errors = require("server.errors")
local motion = require("server.motion")
local breeding = require("server.tasks.breeding")

local cycle = {}

-- Error result after tidying up: whatever the robot carries goes back into the supply
-- chests and the robot returns home (both best effort).
local function fail(ctx, err)
  ctx.log:error(err.msg)
  if ctx.state.carry and next(ctx.state.carry) then
    local ok, stash_err = breeding.stash(ctx)
    if not ok then ctx.log:error(stash_err.msg) end
  end
  motion.home(ctx)
  return { ok = false, error = err }
end

local function take(ctx, at, kind)
  local slot, got = breeding.fetch(ctx, at.id, at.slot, 1, { name = bees.ITEM[kind] })
  if slot then return slot end
  if got.code == "ROBOT_MISMATCH" or got.code == "ROBOT_EMPTY_SLOT" then
    return nil, errors.new("NOT_A_BEE", at.slot, at.id, kind)
  end
  return nil, got
end

-- princess_at, drone_at: { id = position id, slot = chest slot }
function cycle.run(ctx, princess_at, drone_at)
  local lay = ctx.state.layout
  if not (lay and lay.complete) then return { ok = false, error = errors.new("SETUP_NO_LAYOUT") } end
  if next(ctx.state.ledger.chests) == nil then return { ok = false, error = errors.new("INVENTORY_MISSING") } end

  local ok, err = breeding.read_robot(ctx)
  if not ok then return { ok = false, error = err } end
  ok, err = breeding.stash(ctx) -- anything left in the robot from before
  if not ok then return fail(ctx, err) end

  local princess, drone
  princess, err = take(ctx, princess_at, "princess")
  if not princess then return fail(ctx, err) end
  drone, err = take(ctx, drone_at, "drone")
  if not drone then return fail(ctx, err) end
  ctx.log:info("Parents: " .. bees.describe(ctx.state.carry[princess]) .. " + " .. bees.describe(ctx.state.carry[drone]))

  local started = ctx.now()
  local slots
  slots, err = breeding.cross(ctx, princess, drone)
  if not slots then return fail(ctx, err) end
  local seconds = math.floor(ctx.now() - started)

  local lines = { string.format("Cycle finished after about %d s, offspring:", seconds) }
  for _, slot in ipairs(slots) do
    local bee = ctx.state.carry[slot]
    local pristine = bee.natural == false and " (not pristine)" or ""
    lines[#lines + 1] = "  " .. bees.describe(bee) .. pristine
  end

  ok, err = breeding.stash(ctx)
  if not ok then return fail(ctx, err) end
  ok, err = motion.home(ctx)
  if not ok then return { ok = false, error = err, lines = lines } end
  ctx.save("inventory")
  return { ok = true, lines = lines }
end

return cycle
