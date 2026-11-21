-- 'scanall': analyzes every unanalyzed bee stack in the supply and provider chests and
-- puts it back into its slot. Costs one honey drop per stack. Afterwards the planner
-- also knows the hidden inactive species, e.g. drones that carry a target species.

local bees = require("shared.bees")
local errors = require("server.errors")
local layout = require("server.layout")
local motion = require("server.motion")
local breeding = require("server.tasks.breeding")

local scanall = {}

local function fail(ctx, err)
  ctx.log:error(err.msg)
  if ctx.state.carry and next(ctx.state.carry) then
    local ok, stash_err = breeding.stash(ctx)
    if not ok then ctx.log:error(stash_err.msg) end
  end
  motion.home(ctx)
  ctx.save("inventory")
  return { ok = false, error = err }
end

function scanall.run(ctx)
  local lay = ctx.state.layout
  if not (lay and lay.complete) then return { ok = false, error = errors.new("SETUP_NO_LAYOUT") } end
  if next(ctx.state.ledger.chests) == nil then return { ok = false, error = errors.new("INVENTORY_MISSING") } end

  local ok, err = breeding.read_robot(ctx)
  if not ok then return { ok = false, error = err } end
  ok, err = breeding.stash(ctx)
  if not ok then return fail(ctx, err) end

  local order = layout.source_order(lay, false)
  local todo = {}
  for _, hit in ipairs(ctx.state.ledger:find({ analyzed = false }, order)) do
    if hit.bee.kind then todo[#todo + 1] = hit end
  end
  if #todo == 0 then
    ok, err = motion.home(ctx)
    if not ok then return fail(ctx, err) end
    return { ok = true, lines = { "All bees in the chests are analyzed already" } }
  end
  ctx.log:info(string.format("Analyzing %d bee stack(s), one honey drop each", #todo))

  local analyzed, hybrids, skipped = 0, 0, 0
  for i, hit in ipairs(todo) do
    breeding.phase(ctx, string.format("analyzing stack %d of %d", i, #todo))
    local slot, got = breeding.fetch(ctx, hit.chest, hit.slot, hit.bee.size,
      { name = hit.bee.name, species = hit.bee.species })
    if slot then
      ok, err = breeding.analyze(ctx, { slot })
      if not ok then return fail(ctx, err) end
      local bee = ctx.state.carry[slot]
      analyzed = analyzed + 1
      if bees.purity(bee) == false then
        hybrids = hybrids + 1
        ctx.log:info(string.format("  %-5s slot %-3d %s", hit.chest, hit.slot, bees.describe(bee)))
      end
      ok, err = breeding.put_back(ctx, slot, hit.chest, hit.slot)
      if not ok then return fail(ctx, err) end
    elseif got.code == "ROBOT_MISMATCH" or got.code == "ROBOT_EMPTY_SLOT" then
      -- the chest changed since the last scan: read it again and go on
      skipped = skipped + 1
      local scanned, scan_err = breeding.scan_chest(ctx, hit.chest)
      if not scanned then return fail(ctx, scan_err) end
    else
      return fail(ctx, got)
    end
  end

  ok, err = motion.home(ctx)
  if not ok then return fail(ctx, err) end
  ctx.save("inventory")
  local lines = { string.format("Analyzed %d bee stack(s), %d of them hybrids", analyzed, hybrids) }
  if skipped > 0 then
    lines[#lines + 1] = string.format("%d stack(s) had moved; run 'scanall' again to catch them", skipped)
  end
  return { ok = true, lines = lines }
end

return scanall
