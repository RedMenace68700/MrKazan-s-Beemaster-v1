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
    local carrier = { kind = kind, carries = species, natural = natural, not_pure = true }
    local result = { pure = ledger:count(pure, order), unknown = ledger:count(unread, order),
                     carriers = ledger:count(carrier, order), providers = 0 }
    if quest then result.providers = ledger:count(pure, ctx.state.layout.providers) end
    result.any = ledger:count(base, order)
    return result
  end
end

-- The request's products: everything the robot carries except honey.
local function products(ctx)
  local honey = breeding.honey_slot(ctx)
  local carry = {}
  for slot, bee in pairs(ctx.state.carry) do
    if slot ~= honey then carry[slot] = bee end
  end
  return carry
end

-- A bee for a cross: a carried one (exactly one drone), a pure one from stock, or one
-- from stock that carries a species but is not known pure. Returns the robot slot, or
-- nil plus an error object (nil error: the inventory was out of date, plan again).
local function acquire(ctx, source, kind)
  if source.slot then
    local bee = ctx.state.carry[source.slot]
    if kind == "drone" and bee.size > 1 then return breeding.split(ctx, source.slot, 1) end
    return source.slot
  end
  local filter
  if source.carrier then
    filter = { kind = kind, carries = source.carrier, not_pure = true, natural = natural_only(ctx) }
  else
    filter = { kind = kind, species = source.species, pure = true, natural = natural_only(ctx) }
  end
  return breeding.take(ctx, filter, source_order(ctx), 1)
end

-- Drone stacks carrying C (not pure) kept in the robot at most; more go into the chests.
local MAX_HYBRID_DRONES = 6

-- After a cross: keep the request's products in the robot, store everything else.
-- Kept: pure C princesses, the newest princess (the next one to work with), pure C drones
-- and up to MAX_HYBRID_DRONES drone stacks carrying C.
local function sort_out(ctx, entry, offspring)
  local newest
  for _, slot in ipairs(offspring) do
    local bee = ctx.state.carry[slot]
    if bee and bee.kind == "princess" then newest = slot end
  end
  local store, hybrids = {}, {}
  for slot, bee in pairs(products(ctx)) do
    local pure_c = bees.purity(bee) == true and bees.same_species(bee.species, entry.c)
    local carries_c = bees.same_species(bee.species, entry.c) or bees.same_species(bee.inactive, entry.c)
    if bee.kind == "princess" then
      if not (pure_c or slot == newest) then store[#store + 1] = slot end
    elseif bee.kind == "drone" and pure_c then
      -- keep
    elseif bee.kind == "drone" and carries_c then
      hybrids[#hybrids + 1] = slot
    else
      store[#store + 1] = slot
    end
  end
  table.sort(hybrids)
  for i = MAX_HYBRID_DRONES + 1, #hybrids do store[#store + 1] = hybrids[i] end
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

-- Robot slots of the carried pure C princesses and pure C drones.
local function pure_slots(ctx, c)
  local princesses, drones = {}, {}
  for slot, bee in pairs(products(ctx)) do
    if bees.purity(bee) == true and bees.same_species(bee.species, c) then
      if bee.kind == "princess" then
        princesses[#princesses + 1] = slot
      elseif bee.kind == "drone" then
        drones[#drones + 1] = slot
      end
    end
  end
  table.sort(princesses)
  table.sort(drones)
  return princesses, drones
end

local function free_robot_slots(ctx)
  local free = 0
  local honey = breeding.honey_slot(ctx)
  for slot = 1, ctx.state.robot_size or 16 do
    if slot ~= honey and ctx.state.carry[slot] == nil then free = free + 1 end
  end
  return free
end

-- A pure C bee for a multiply cycle: a carried one, else one from stock (unread ones are
-- looked at first). Returns the robot slot, or nil plus an error object.
local function pure_bee(ctx, c, kind, carried)
  if carried then return acquire(ctx, { slot = carried }, kind) end
  local count = stock_counter(ctx)
  for _ = 1, ANALYZE_LIMIT do
    local st = count(kind, c)
    if st.pure > 0 then
      local slot, err = acquire(ctx, { species = c }, kind)
      if slot or err then return slot, err end
    elseif st.unknown > 0 then
      local ok, err = analyze_candidate(ctx, { kind = kind, species = c })
      if not ok then return nil, err end
    else
      return nil, errors.new(kind == "princess" and "MISSING_PRINCESS" or "MISSING_DRONE", c)
    end
  end
  return nil, errors.new(kind == "princess" and "MISSING_PRINCESS" or "MISSING_DRONE", c)
end

-- "= C X": breeds a pure C princess with a pure C drone X times. Each cycle uses the new
-- princess and one of the new drones. At the end the princess and all pure C drones go
-- into the provider chests. DroneSafetyMode does not apply: the pair is pure C x pure C.
local function multiply(ctx, entry)
  local c, name = entry.c, queue.describe(entry)
  local order = layout.deliver_order(ctx.state.layout)
  local ok, err = breeding.ensure_honey(ctx, 1)
  if not ok then return { status = "halt", error = err } end

  for cycle = 1, entry.count do
    if ctx.stopping() then return { status = "stopped" } end
    ok, err = breeding.charge(ctx)
    if not ok then return { status = "halt", error = err } end
    ctx.state.progress = { request = "#" .. entry.id .. " " .. name, cycle = cycle, max = entry.count,
                           note = "pure " .. c .. " pair" }
    ctx.log:info(string.format("= %s: cycle %d of %d", c, cycle, entry.count))

    local princesses, drones = pure_slots(ctx, c)
    local princess, drone
    princess, err = pure_bee(ctx, c, "princess", princesses[1])
    if not princess then
      return { status = MISSING[err.code] and "missing" or "halt", error = err }
    end
    drone, err = pure_bee(ctx, c, "drone", drones[1])
    if not drone then
      if not princesses[1] then
        local stored, store_err = breeding.store_slots(ctx, { princess })
        if not stored then return { status = "halt", error = store_err } end
      end
      return { status = MISSING[err.code] and "missing" or "halt", error = err }
    end
    ctx.log:info("  " .. bees.describe(ctx.state.carry[princess]) .. " x " .. bees.describe(ctx.state.carry[drone]))

    local offspring
    offspring, err = breeding.cross(ctx, princess, drone)
    if not offspring then
      return { status = err.code == "CYCLE_TIMEOUT" and "failed" or "halt", error = err }
    end
    local names = {}
    for _, slot in ipairs(offspring) do names[#names + 1] = bees.describe(ctx.state.carry[slot]) end
    ctx.log:info("  offspring: " .. table.concat(names, ", "))

    -- keep the pure C bees, store anything else
    local store = {}
    for slot, bee in pairs(products(ctx)) do
      if not (bees.purity(bee) == true and bees.same_species(bee.species, c)) then store[#store + 1] = slot end
    end
    ok, err = breeding.store_slots(ctx, store)
    if not ok then return { status = "halt", error = err } end

    -- the robot fills up: hand the drones over early, keep one for the next cycle
    if free_robot_slots(ctx) < 3 then
      local _, carried = pure_slots(ctx, c)
      for i = 2, #carried do
        ok, err = breeding.store(ctx, carried[i], order, "PROVIDER_FULL")
        if not ok then return { status = "halt", error = err } end
      end
    end
  end

  local princesses, drones = pure_slots(ctx, c)
  for _, slot in ipairs(princesses) do
    ok, err = breeding.store(ctx, slot, order, "PROVIDER_FULL")
    if not ok then return { status = "halt", error = err } end
  end
  for _, slot in ipairs(drones) do
    ok, err = breeding.store(ctx, slot, order, "PROVIDER_FULL")
    if not ok then return { status = "halt", error = err } end
  end
  return { status = "done", cycles = entry.count }
end

function request.run(ctx, entry)
  if entry.count then return multiply(ctx, entry) end
  local settings = ctx.settings
  local need = settings:get("ResultMode") == "extra_spares" and settings:get("SpareDrones") or 1
  local max_cycles = settings:get("MaxCyclesPerRequest")
  local name = queue.describe(entry)
  local cycles, looks = 0, 0

  ctx.state.progress = { request = "#" .. entry.id .. " " .. name, cycle = 0, max = max_cycles, note = "preparing" }
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
      ctx.state.progress = { request = "#" .. entry.id .. " " .. name, cycle = cycles, max = max_cycles, note = note }
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
