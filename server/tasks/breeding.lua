-- Building blocks for breeding, used by the cycle task and later by the planner:
-- taking bees out of chests, storing them, honey, the apiary cycle and analysis.
--
-- The server keeps track of what the robot carries in ctx.state.carry (slot -> summary);
-- read_robot() refreshes it from the robot. The honey slot (see honey_slot) only
-- ever holds honey drops.
--
-- All functions return a result or nil plus an error object.

local grid = require("shared.grid")
local bees = require("shared.bees")
local errors = require("server.errors")
local layout = require("server.layout")
local motion = require("server.motion")
local replies = require("server.replies")

local breeding = {}

local HONEY_STACK = 64
-- Refill the honey slot when fewer drops than this are left.
local HONEY_REFILL_BELOW = 16

local function station(id)
  return grid.position(id)
end

-- The robot slot that holds honey: config.honey_slot if set (> 0), else the robot's last slot.
function breeding.honey_slot(ctx)
  local configured = ctx.config.honey_slot
  if configured and configured > 0 then return configured end
  return ctx.state.robot_size or 16
end

-- Reads the robot inventory into ctx.state.carry.
function breeding.read_robot(ctx)
  local reply = ctx.call("inventory")
  if not reply.ok then return nil, replies.error(reply) end
  ctx.state.carry = reply.data.slots
  ctx.state.robot_size = reply.data.size
  return true
end

function breeding.free_robot_slot(ctx)
  local honey = breeding.honey_slot(ctx)
  for slot = 1, ctx.state.robot_size or 16 do
    if slot ~= honey and ctx.state.carry[slot] == nil then return slot end
  end
  return nil
end

-- Scans one inventory chest again and refreshes the ledger.
function breeding.scan_chest(ctx, id)
  local ok, err = motion.go(ctx, station(id))
  if not ok then return nil, err end
  local reply = ctx.call("scan")
  if not reply.ok then return nil, replies.error(reply, { at = id }) end
  ctx.state.ledger:set_chest(id, reply.data.size, reply.data.slots, ctx.clock())
  return reply.data
end

-- Fetches from chest `id` slot `slot` into a free robot slot. expect: name, species,
-- inactive. Returns the robot slot and the summary of what it now holds, or nil plus an
-- error object (the robot's code in err.code, e.g. ROBOT_MISMATCH).
function breeding.fetch(ctx, id, slot, count, expect)
  local into = breeding.free_robot_slot(ctx)
  if not into then return nil, errors.new("ROBOT_FULL") end
  local ok, err = motion.go(ctx, station(id))
  if not ok then return nil, err end
  local reply = ctx.call("fetch", { slot = slot, count = count, into = into, expect = expect })
  if not reply.ok then return nil, replies.error(reply, { at = id, expected = expect and expect.species }) end
  if ctx.state.ledger:chest(id) then ctx.state.ledger:set_slot(id, slot, reply.data.left) end
  ctx.state.carry[into] = reply.data.got
  return into, reply.data.got
end

-- Takes `count` items of a bee matching filter out of the chests in `order`, trusting the
-- inventory but checking every slot before taking (see Ledger:locate).
-- Returns robot slot and the bee summary, or nil plus an error object (nil error = none found).
function breeding.take(ctx, filter, order, count)
  local fatal, taken_slot, taken_bee
  local hit = ctx.state.ledger:locate(filter, order, {
    verify = function(candidate)
      if fatal then return true end
      local bee = candidate.bee
      local expect = { name = bee.name, species = bee.species, inactive = bee.inactive }
      local slot, got = breeding.fetch(ctx, candidate.chest, candidate.slot, count or 1, expect)
      if slot then
        taken_slot, taken_bee = slot, got
        return true
      end
      local err = got
      if err.code == "ROBOT_MISMATCH" or err.code == "ROBOT_EMPTY_SLOT" then return false end
      fatal = err
      return true
    end,
    rescan = function(id)
      if fatal then return end
      local ok, err = breeding.scan_chest(ctx, id)
      if not ok then fatal = err end
    end,
  })
  if fatal then return nil, fatal end
  if not hit then return nil, nil end
  return taken_slot, taken_bee
end

-- Puts the item in robot slot `from` into the first chest of `order` that has room.
-- full_code: error code when every chest is full. Returns chest id and slot.
function breeding.store(ctx, from, order, full_code)
  local ledger = ctx.state.ledger
  for _, id in ipairs(order) do
    local tries = 0
    while ledger:free_slots(id) > 0 and tries < 3 do
      tries = tries + 1
      local ok, err = motion.go(ctx, station(id))
      if not ok then return nil, err end
      local reply = ctx.call("put", { from = from, slot = ledger:first_free_slot(id) })
      if reply.ok then
        ledger:set_slot(id, reply.data.slot, reply.data.stack)
        ctx.state.carry[from] = nil
        return id, reply.data.slot
      elseif reply.err == "ROBOT_SLOT_BUSY" then
        local scanned, scan_err = breeding.scan_chest(ctx, id) -- the inventory was out of date
        if not scanned then return nil, scan_err end
      elseif reply.err == "ROBOT_CHEST_FULL" then
        local scanned, scan_err = breeding.scan_chest(ctx, id)
        if not scanned then return nil, scan_err end
        break
      else
        return nil, replies.error(reply, { at = id })
      end
    end
  end
  return nil, errors.new(full_code)
end

-- Stores the given robot slots in the supply chests.
function breeding.store_slots(ctx, slots)
  local order = layout.store_order(ctx.state.layout)
  table.sort(slots)
  for _, slot in ipairs(slots) do
    if ctx.state.carry[slot] then
      local ok, err = breeding.store(ctx, slot, order, "SUPPLY_FULL")
      if not ok then return nil, err end
    end
  end
  return true
end

-- Stores everything the robot carries (except honey) in the supply chests.
function breeding.stash(ctx)
  local honey = breeding.honey_slot(ctx)
  local slots = {}
  for slot in pairs(ctx.state.carry) do
    if slot ~= honey then slots[#slots + 1] = slot end
  end
  return breeding.store_slots(ctx, slots)
end

-- Puts an item back into the chest slot it came from (or anywhere in the supply chests
-- if that slot was taken meanwhile).
function breeding.put_back(ctx, from, id, slot)
  local ok, err = motion.go(ctx, station(id))
  if not ok then return nil, err end
  local reply = ctx.call("put", { from = from, slot = slot })
  if reply.ok then
    if ctx.state.ledger:chest(id) then ctx.state.ledger:set_slot(id, reply.data.slot, reply.data.stack) end
    ctx.state.carry[from] = nil
    return true
  end
  if reply.err ~= "ROBOT_SLOT_BUSY" then return nil, replies.error(reply, { at = id }) end
  return breeding.store_slots(ctx, { from })
end

-- Moves `count` items of a robot slot into a free robot slot. Returns the new slot.
function breeding.split(ctx, from, count)
  local to = breeding.free_robot_slot(ctx)
  if not to then return nil, errors.new("ROBOT_FULL") end
  local reply = ctx.call("split", { from = from, to = to, count = count })
  if not reply.ok then return nil, replies.error(reply) end
  ctx.state.carry[from] = reply.data.from
  ctx.state.carry[to] = reply.data.to
  return to
end

-- Sends the robot home to charge when its energy is low, and waits until it is full.
function breeding.charge(ctx)
  local reply = ctx.call("status")
  if not reply.ok then return nil, replies.error(reply) end
  local d = reply.data
  if not d.max_energy or d.max_energy <= 0 or d.energy / d.max_energy >= 0.25 then return true end
  ctx.log:info(string.format("Energy at %d%%, charging at home", math.floor(d.energy / d.max_energy * 100)))
  local ok, err = motion.home(ctx)
  if not ok then return nil, err end
  for _ = 1, 60 do
    ctx.sleep(15)
    reply = ctx.call("status")
    if not reply.ok then return nil, replies.error(reply) end
    if reply.data.energy / reply.data.max_energy >= 0.95 then return true end
  end
  return true
end

-- Makes sure the robot carries at least `need` honey drops, refilling from the honey chest.
-- Fails with HONEY_LOW when robot and honey chest together hold less than MinHoney.
function breeding.ensure_honey(ctx, need)
  local honey_slot = breeding.honey_slot(ctx)
  local held = ctx.state.carry[honey_slot]
  local have = held and held.name == bees.ITEM.honey and held.size or 0
  if held and held.name ~= bees.ITEM.honey then
    return nil, errors.new("ROBOT_SLOT_BUSY", honey_slot)
  end
  if have >= need and have >= HONEY_REFILL_BELOW then return true end

  local id = ctx.state.layout.honey
  local ok, err = motion.go(ctx, station(id))
  if not ok then return nil, err end
  local reply = ctx.call("scan")
  if not reply.ok then return nil, replies.error(reply, { at = id }) end
  local in_chest = 0
  local sources = {}
  for slot = 1, reply.data.size do
    local item = reply.data.slots[slot]
    if item and item.name == bees.ITEM.honey then
      in_chest = in_chest + item.size
      sources[#sources + 1] = { slot = slot, size = item.size }
    end
  end
  local min_honey = ctx.settings:get("MinHoney")
  if have + in_chest < math.max(need, min_honey) then
    return nil, errors.new("HONEY_LOW", have + in_chest, min_honey)
  end
  for _, source in ipairs(sources) do
    if have >= HONEY_STACK then break end
    local count = math.min(HONEY_STACK - have, source.size)
    local got = ctx.call("fetch", { slot = source.slot, count = count, into = honey_slot,
                                    expect = { name = bees.ITEM.honey } })
    if not got.ok then return nil, replies.error(got, { at = id }) end
    have = have + got.data.moved
  end
  ctx.state.carry[honey_slot] = { name = bees.ITEM.honey, size = have }
  if have < need then return nil, errors.new("HONEY_LOW", have, min_honey) end
  return true
end

-- Analyzes the unanalyzed bees in the given robot slots.
function breeding.analyze(ctx, slots)
  local todo = {}
  for _, slot in ipairs(slots) do
    local bee = ctx.state.carry[slot]
    if bee and bee.kind and not bee.analyzed then todo[#todo + 1] = slot end
  end
  if #todo == 0 then return true end
  local ok, err = breeding.ensure_honey(ctx, #todo)
  if not ok then return nil, err end
  local honey_slot = breeding.honey_slot(ctx)
  for _, slot in ipairs(todo) do
    local reply = ctx.call("analyze", { slot = slot, honey = honey_slot })
    if not reply.ok then return nil, replies.error(reply) end
    ctx.state.carry[slot] = reply.data.bee
    ctx.state.carry[honey_slot] = { name = bees.ITEM.honey, size = reply.data.honey }
  end
  return true
end

-- Puts a bee from a robot slot into the apiary. kind: "princess" or "drone".
-- If the queen slot was not empty, the swap is undone and APIARY_BUSY returned.
function breeding.insert(ctx, slot, kind)
  local id = ctx.state.layout.apiary
  local position = station(id)
  local ok, err = motion.go(ctx, position)
  if not ok then return nil, err end
  local side = grid.DIRECTIONS[position.facing].side
  local bee = ctx.state.carry[slot]
  local reply = ctx.call("insert", { from = slot, kind = kind, side = side, expect = { species = bee and bee.species } })
  if not reply.ok then return nil, replies.error(reply, { command = "insert" }) end
  local back = reply.data.back
  ctx.state.carry[slot] = back
  if back and kind == "princess" then
    -- something was still working in the apiary: put it back and get our princess out
    local undo = ctx.call("insert", { from = slot, kind = back.kind, side = side })
    if undo.ok then ctx.state.carry[slot] = undo.data.back end
    return nil, errors.new("APIARY_BUSY", bees.describe(back))
  end
  return true
end

-- Bees lying in the output chest, as a list of { slot, bee }.
local function bees_in(scan)
  local found = {}
  for slot = 1, scan.size do
    local item = scan.slots[slot]
    if item and item.kind then found[#found + 1] = { slot = slot, bee = item } end
  end
  return found
end

-- Takes every bee out of the output chest (combs stay). Returns the robot slots.
function breeding.collect(ctx, scan)
  local id = ctx.state.layout.output
  if not scan then
    local ok, err = motion.go(ctx, station(id))
    if not ok then return nil, err end
    local reply = ctx.call("scan")
    if not reply.ok then return nil, replies.error(reply, { at = id }) end
    scan = reply.data
  end
  local slots = {}
  for _, found in ipairs(bees_in(scan)) do
    local into, err = breeding.fetch(ctx, id, found.slot, found.bee.size, { name = found.bee.name, species = found.bee.species })
    if not into then return nil, err end
    slots[#slots + 1] = into
  end
  return slots
end

-- One apiary cycle with the princess and the single drone in the given robot slots:
-- clear the output chest of old bees, check its free room, insert both, wait, collect
-- and analyze the offspring. Returns the robot slots of the offspring.
function breeding.cross(ctx, princess_slot, drone_slot)
  local id = ctx.state.layout.output
  local ok, err = motion.go(ctx, station(id))
  if not ok then return nil, err end
  local reply = ctx.call("scan")
  if not reply.ok then return nil, replies.error(reply, { at = id }) end
  local used = 0
  for _ in pairs(reply.data.slots) do used = used + 1 end
  local leftovers
  leftovers, err = breeding.collect(ctx, reply.data)
  if not leftovers then return nil, err end
  if #leftovers > 0 then
    ctx.log:info(string.format("Cleared %d old bee stack(s) from the output chest", #leftovers))
    ok, err = breeding.store_slots(ctx, leftovers)
    if not ok then return nil, err end
  end
  local free = reply.data.size - used + #leftovers
  local min_free = ctx.settings:get("MinFreeOutputSlots")
  if free < min_free then return nil, errors.new("OUTPUT_FULL", free, min_free) end

  local timeout = ctx.settings:get("CycleTimeout")
  ok, err = breeding.insert(ctx, princess_slot, "princess")
  if not ok and err.code == "APIARY_BUSY" then
    -- something is still working in the apiary (e.g. after a restart): let it finish
    ctx.log:warn(err.msg .. "; waiting for it to finish")
    local scan
    scan, err = breeding.wait_offspring(ctx, timeout)
    if not scan then return nil, err end
    local old
    old, err = breeding.collect(ctx, scan)
    if not old then return nil, err end
    ok, err = breeding.store_slots(ctx, old)
    if not ok then return nil, err end
    ok, err = breeding.insert(ctx, princess_slot, "princess")
  end
  if not ok then return nil, err end
  ok, err = breeding.insert(ctx, drone_slot, "drone")
  if not ok then return nil, err end

  local scan
  scan, err = breeding.wait_offspring(ctx, timeout)
  if not scan then return nil, err end
  local slots
  slots, err = breeding.collect(ctx, scan)
  if not slots then return nil, err end
  ok, err = breeding.analyze(ctx, slots)
  if not ok then return nil, err end
  return slots
end

-- Waits at the output chest until a princess appears. Returns the scan of the chest.
function breeding.wait_offspring(ctx, timeout)
  local id = ctx.state.layout.output
  local ok, err = motion.go(ctx, station(id))
  if not ok then return nil, err end
  local started = ctx.now()
  while true do
    local reply = ctx.call("scan")
    if not reply.ok then return nil, replies.error(reply, { at = id }) end
    for _, found in ipairs(bees_in(reply.data)) do
      if found.bee.kind == "princess" then return reply.data end
    end
    if ctx.now() - started >= timeout then return nil, errors.new("CYCLE_TIMEOUT", timeout) end
    ctx.sleep(ctx.config.output_check_interval)
  end
end

return breeding
