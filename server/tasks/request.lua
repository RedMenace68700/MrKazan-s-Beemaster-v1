-- Works on one request A + B = C until its result is delivered, it cannot go on, or
-- the player stops. The planner (server/planner.lua) decides each step; this module
-- carries the steps out with the robot.
--
-- Returns an outcome:
--   { status = "done", cycles = n }
--   { status = "missing", error }   bees missing (OnMissing decides: skip or halt)
--   { status = "failed", error }    no result (MAX_CYCLES, CYCLE_TIMEOUT)
--   { status = "halt", error }      the run cannot go on (robot, chests, honey, ...)
--   { status = "stopped" }          the player typed 'stop'

local bees = require("shared.bees")
local errors = require("server.errors")
local layout = require("server.layout")
local planner = require("server.planner")
local queue = require("server.queue")
local breeding = require("server.tasks.breeding")

local request = {}

local ANALYZE_LIMIT = 100

local function natural_only(ctx)
  return ctx.settings:get("PristineMode") == "PristineOnly" or nil
end

local function source_order(ctx)
  return layout.source_order(ctx.state.layout, ctx.settings:get("QuestMode"))
end

-- Counts bees in the allowed chests for the planner.
local function stock_counter(ctx)
  local ledger = ctx.state.ledger
  local order = source_order(ctx)
  local natural = natural_only(ctx)
  local quest = ctx.settings:get("QuestMode")
  return function(kind, species)
    local base = { kind = kind, species = species, natural = natural }
    local pure = { kind = kind, species = species, natural = natural, pure = true }
    local unread = { kind = kind, species = species, natural = natural, analyzed = false }
    local result = { pure = ledger:count(pure, order), unknown = ledger:count(unread, order), providers = 0 }
    if quest then result.providers = ledger:count(pure, ctx.state.layout.providers) end
    result.any = ledger:count(base, order)
    return result
  end
end

-- The request's products: everything the robot carries except honey.
local function products(ctx)
  local honey = ctx.config.honey_slot
  local carry = {}
  for slot, bee in pairs(ctx.state.carry) do
    if slot ~= honey then carry[slot] = bee end
  end
  return carry
end

-- A bee for a cross: a carried one (exactly one drone) or a pure one from stock.
-- Returns the robot slot, or nil plus an error object (nil error: the inventory was out
-- of date, plan again).
local function acquire(ctx, source, kind)
  if source.slot then
    local bee = ctx.state.carry[source.slot]
    if kind == "drone" and bee.size > 1 then return breeding.split(ctx, source.slot, 1) end
    return source.slot
  end
  local filter = { kind = kind, species = source.species, pure = true, natural = natural_only(ctx) }
  return breeding.take(ctx, filter, source_order(ctx), 1)
end

-- After a cross: keep the request's products in the robot, store everything else.
-- Kept: pure C princesses, the newest other princess (next working princess), pure C drones.
local function sort_out(ctx, entry, offspring)
  local newest
  for _, slot in ipairs(offspring) do
    local bee = ctx.state.carry[slot]
    if bee and bee.kind == "princess" then newest = slot end
  end
  local store = {}
  for slot, bee in pairs(products(ctx)) do
    local pure_c = bees.purity(bee) == true and bees.same_species(bee.species, entry.c)
    local keep = (bee.kind == "princess" and (pure_c or slot == newest)) or (bee.kind == "drone" and pure_c)
    if not keep then store[#store + 1] = slot end
  end
  return breeding.store_slots(ctx, store)
end

-- Looks at one unanalyzed candidate in stock and puts it back where it was.
local function analyze_candidate(ctx, step)
  local filter = { kind = step.kind, species = step.species, analyzed = false, natural = natural_only(ctx) }
  local hit = ctx.state.ledger:find(filter, source_order(ctx))[1]
  if not hit then return true end
  local count = step.kind == "drone" and hit.bee.size or 1
  local slot, got = breeding.fetch(ctx, hit.chest, hit.slot, count, { name = hit.bee.name, species = hit.bee.species })
  if not slot then
    if got.code == "ROBOT_MISMATCH" or got.code == "ROBOT_EMPTY_SLOT" then
      return breeding.scan_chest(ctx, hit.chest)
    end
    return nil, got
  end
  local ok, err = breeding.analyze(ctx, { slot })
  if not ok then return nil, err end
  ctx.log:info("Analyzed " .. bees.describe(ctx.state.carry[slot]) .. " from " .. hit.chest)
  return breeding.put_back(ctx, slot, hit.chest, hit.slot)
end

-- Puts the result into the provider chests: one pure C princess and exactly `need` drones.
local function deliver(ctx, step, need)
  local order = layout.deliver_order(ctx.state.layout)
  local ok, err = breeding.store(ctx, step.princess, order, "PROVIDER_FULL")
  if not ok then return nil, err end
  local remaining = need
  for _, slot in ipairs(step.drones) do
    if remaining <= 0 then break end
    local size = ctx.state.carry[slot].size or 1
    local part = slot
    if size > remaining then
      part, err = breeding.split(ctx, slot, remaining)
      if not part then return nil, err end
      size = remaining
    end
    ok, err = breeding.store(ctx, part, order, "PROVIDER_FULL")
    if not ok then return nil, err end
    remaining = remaining - size
  end
  return true
end

-- One cross step from the planner ("cross" or "stock"). Returns true, or false when the
-- inventory was out of date (plan again), or nil plus an error object.
local function cross(ctx, entry, step)
  local princess_source, drone_source = step.princess, step.drone
  if step.action == "stock" then
    princess_source, drone_source = { species = step.species }, { species = step.species }
  end
  local princess, err = acquire(ctx, princess_source, "princess")
  if not princess then
    if err then return nil, err end
    return false
  end
  local drone
  drone, err = acquire(ctx, drone_source, "drone")
  if not drone then
    if err then return nil, err end
    -- put the princess back among the products / stock, then plan again
    if princess_source.species then
      local ok, store_err = breeding.store_slots(ctx, { princess })
      if not ok then return nil, store_err end
    end
    return false
  end
  ctx.log:info("  " .. bees.describe(ctx.state.carry[princess]) .. " x " .. bees.describe(ctx.state.carry[drone]))

  local offspring
  offspring, err = breeding.cross(ctx, princess, drone)
  if not offspring then return nil, err end
  local names = {}
  for _, slot in ipairs(offspring) do names[#names + 1] = bees.describe(ctx.state.carry[slot]) end
  ctx.log:info("  offspring: " .. table.concat(names, ", "))

  if step.action == "stock" then
    -- AutoStocking: all offspring are stock for later, not products of this request
    return breeding.store_slots(ctx, offspring)
  end
  return sort_out(ctx, entry, offspring)
end

local MISSING = { MISSING_PRINCESS = true, MISSING_DRONE = true, DRONE_SAFETY = true, QUEST_LAST_PRINCESS = true }

function request.run(ctx, entry)
  local settings = ctx.settings
  local need = settings:get("ResultMode") == "extra_spares" and settings:get("SpareDrones") or 1
  local max_cycles = settings:get("MaxCyclesPerRequest")
  local name = queue.describe(entry)
  local cycles, looks = 0, 0

  local ok, err = breeding.ensure_honey(ctx, 1)
  if not ok then return { status = "halt", error = err } end

  while true do
    if ctx.stopping() then return { status = "stopped" } end
    ok, err = breeding.charge(ctx)
    if not ok then return { status = "halt", error = err } end

    local step = planner.decide({
      a = entry.a, b = entry.b, c = entry.c,
      carry = products(ctx),
      stock = stock_counter(ctx),
      need_drones = need,
      drone_safety = settings:get("DroneSafetyMode"),
      auto_stocking = settings:get("AutoStocking"),
      quest_mode = settings:get("QuestMode"),
    })

    if step.action == "deliver" then
      ok, err = deliver(ctx, step, need)
      if not ok then return { status = "halt", error = err } end
      return { status = "done", cycles = cycles }
    elseif step.action == "fail" then
      return { status = "missing", error = errors.new(step.code, step.species) }
    elseif step.action == "analyze" then
      looks = looks + 1
      if looks > ANALYZE_LIMIT then return { status = "halt", error = errors.new("SERVER_INTERNAL", "too many analyses") } end
      ok, err = analyze_candidate(ctx, step)
      if not ok then return { status = "halt", error = err } end
    else
      if cycles >= max_cycles then return { status = "failed", error = errors.new("MAX_CYCLES", cycles) } end
      cycles = cycles + 1
      local note = step.action == "stock" and ("AutoStocking: more " .. step.species .. " drones") or step.note
      ctx.log:info(string.format("%s: cycle %d, %s", name, cycles, note))
      local done
      done, err = cross(ctx, entry, step)
      if done == false then
        cycles = cycles - 1 -- nothing happened, the inventory was out of date
      elseif not done then
        if err.code == "CYCLE_TIMEOUT" then return { status = "failed", error = err } end
        if MISSING[err.code] then return { status = "missing", error = err } end
        return { status = "halt", error = err }
      end
    end
  end
end

return request
