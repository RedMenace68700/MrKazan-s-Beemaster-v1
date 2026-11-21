-- 'setup' and 'inventorysetup'.
--
-- setup: the robot starts on its charger (field 6), visits every position of the grid,
-- reports what stands there and returns home. The result becomes the layout. Missing
-- required components are reported; missing optional chests are fine.
-- inventorysetup: setup, then every provider and supply chest is scanned into the
-- inventory.
--
-- ctx = { call, stopping, log, state = { pos, home, layout, ledger }, save(name), clock() }

local grid = require("shared.grid")
local bees = require("shared.bees")
local errors = require("server.errors")
local layout = require("server.layout")
local motion = require("server.motion")
local replies = require("server.replies")

local setup = {}

setup.REQUIRED_COMPONENTS = {
  { name = "inventory_controller", text = "inventory controller upgrade" },
  { name = "navigation", text = "navigation upgrade" },
  { name = "beekeeper", text = "beekeeper upgrade" },
}

-- Move errors after which setup cannot go on (anything but a blocked path).
local function fatal(err)
  return err.code ~= "ROBOT_BLOCKED"
end

local function fail(ctx, err)
  ctx.log:error(err.msg)
  return { ok = false, error = err }
end

local function check_robot(ctx)
  local status = ctx.call("status")
  if not status.ok then return nil, replies.error(status) end
  local present = {}
  for _, name in ipairs(status.data.components or {}) do present[name] = true end
  for _, component in ipairs(setup.REQUIRED_COMPONENTS) do
    if not present[component.name] then
      return nil, errors.new("ROBOT_COMPONENT_MISSING", component.text)
    end
  end
  return status.data
end

-- Scans every provider and supply chest of the layout into the inventory.
function setup.scan_chests(ctx)
  local lay = ctx.state.layout
  local ledger = ctx.state.ledger
  local wanted = {}
  for _, id in ipairs(lay.providers) do wanted[#wanted + 1] = id end
  for _, id in ipairs(lay.supplies) do wanted[#wanted + 1] = id end
  local keep = {}
  for _, id in ipairs(wanted) do keep[id] = true end
  for id in pairs(ledger.chests) do
    if not keep[id] then ledger:forget(id) end
  end
  for _, id in ipairs(wanted) do
    if ctx.stopping() then return nil, nil, true end
    local ok, err = motion.go(ctx, grid.position(id))
    if not ok then return nil, err end
    local reply = ctx.call("scan")
    if not reply.ok then return nil, replies.error(reply, { at = id }) end
    ledger:set_chest(id, reply.data.size, reply.data.slots, ctx.clock())
    local items, bee_count = 0, 0
    for _, summary in pairs(reply.data.slots) do
      items = items + 1
      if summary.kind then bee_count = bee_count + 1 end
    end
    ctx.log:info(string.format("  %-5s %d/%d slots used, %d with bees", id, items, reply.data.size, bee_count))
  end
  ctx.save("inventory")
  return true
end

-- opts.scan = true for inventorysetup
function setup.run(ctx, opts)
  opts = opts or {}
  local robot, err = check_robot(ctx)
  if not robot then return fail(ctx, err) end

  -- The robot stands on its charger: this is where the grid starts.
  local nav = robot.nav or {}
  if nav.x then
    ctx.state.home = { x = nav.x, y = nav.y, z = nav.z }
  else
    ctx.state.home = nil
    ctx.log:warn("Navigation gives no position (outside the map area?); positions cannot be checked")
  end
  ctx.state.pos = { x = grid.HOME.x, y = grid.HOME.y, h = grid.HOME.h, facing = grid.direction_of_side(nav.facing) }
  ctx.log:info("Setup: checking all positions")

  local probes = {}
  local stopped = false
  for _, position in ipairs(grid.positions()) do
    if ctx.stopping() then
      stopped = true
      break
    end
    local ok, move_err = motion.go(ctx, position)
    if ok then
      local reply = ctx.call("probe")
      if not reply.ok then return fail(ctx, replies.error(reply, { at = position.id })) end
      if reply.data.size > 0 then
        probes[position.id] = { size = reply.data.size }
        local name = reply.data.name and (" [" .. tostring(reply.data.name) .. "]") or ""
        ctx.log:info(string.format("  %-5s %-8s %d slots%s", position.id, position.role, reply.data.size, name))
      end
    elseif fatal(move_err) then
      return fail(ctx, move_err)
    else
      ctx.log:warn(string.format("  %-5s not reachable: %s", position.id, move_err.msg))
    end
  end

  local ok, home_err = motion.home(ctx)
  if not ok then return fail(ctx, home_err) end
  if stopped then return { ok = false, stopped = true, lines = { "Setup stopped" } } end

  local lay, problems = layout.evaluate(probes)
  lay.home = ctx.state.home
  lay.complete = #problems == 0
  ctx.state.layout = lay
  ctx.save("layout")
  if #problems > 0 then
    for _, problem in ipairs(problems) do ctx.log:error(problem) end
    return { ok = false, error = { code = "SETUP_MISSING", msg = problems[1] }, problems = problems }
  end

  local lines = {
    string.format("Setup complete: %d provider chest(s), %d supply chest(s)", #lay.providers, #lay.supplies),
  }
  if opts.scan then
    ctx.log:info("Scanning all chests")
    local scanned, scan_err, scan_stopped = setup.scan_chests(ctx)
    local back, back_err = motion.home(ctx)
    if scan_stopped then return { ok = false, stopped = true, lines = { "Inventory scan stopped" } } end
    if not scanned then return fail(ctx, scan_err) end
    if not back then return fail(ctx, back_err) end
    local order = layout.source_order(lay, false)
    local count = ctx.state.ledger:count({}, order)
    local bee_count = 0
    for _, hit in ipairs(ctx.state.ledger:find({}, order)) do
      if bees.kind(hit.bee.name) then bee_count = bee_count + (hit.bee.size or 1) end
    end
    lines[#lines + 1] = string.format("Inventory: %d items, %d bees", count, bee_count)
  end
  return { ok = true, lines = lines }
end

return setup
