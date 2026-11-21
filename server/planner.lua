-- Decides the next step of a request A + B = C. Pure logic on a snapshot, no robot.
--
-- The products of a request (its working princess, pure C princesses, pure C drones)
-- stay in the robot until they are delivered; everything else goes back into the chests.
--
-- snapshot = {
--   a, b, c,                        species of the request
--   carry = { [slot] = summary },   products the robot carries (honey excluded)
--   stock(kind, species) -> { pure = n, unknown = n, providers = n }
--                                   bees in the allowed chests: known pure, not yet
--                                   analyzed, and (QuestMode) pure ones only in providers
--   need_drones,                    1 (single_pair) or SpareDrones (extra_spares)
--   drone_safety, auto_stocking, quest_mode
-- }
--
-- Steps (the first rule that applies wins):
--   1 { action = "deliver", princess = slot, drones = { slot, ... } }  target reached
--   2 C x C: a pure C princess with a pure C drone (carried, else from stock)
--   3 a pure C princess but no pure C drone anywhere: keep her, mutate with another princess
--   4 recovery: no pure C princess, but pure C drones: working princess x C drone
--   5 mutation: working princess x the parent drone she is missing
--   6 mutation: fresh pure parent princess from stock x pure drone of the other parent
-- Other steps:
--   { action = "cross", princess = source, drone = source, note = text }
--       source = { slot = n } (carried) or { species = "X" } (pure one from stock)
--   { action = "analyze", kind = "princess"|"drone", species = "X" }  look at unread bees first
--   { action = "stock", species = "X" }   AutoStocking: breed X x X for more drones
--   { action = "fail", code = "MISSING_PRINCESS"|..., species = "X" }

local bees = require("shared.bees")

local planner = {}

local function same(a, b)
  return bees.same_species(a, b)
end

local function carries(bee, species)
  return same(bee.species, species) or same(bee.inactive, species)
end

local function pure_of(bee, species)
  return bees.purity(bee) == true and same(bee.species, species)
end

-- Sorts the carried products. The working princess is the newest princess that is not
-- pure C (highest generation).
function planner.products(snapshot)
  local p = { pure_princesses = {}, working = nil, c_drones = {}, c_drone_count = 0 }
  local slots = {}
  for slot in pairs(snapshot.carry) do slots[#slots + 1] = slot end
  table.sort(slots)
  local working_generation = -1
  for _, slot in ipairs(slots) do
    local bee = snapshot.carry[slot]
    if bee.kind == "princess" then
      if pure_of(bee, snapshot.c) then
        p.pure_princesses[#p.pure_princesses + 1] = slot
      elseif (bee.generation or 0) > working_generation then
        p.working, working_generation = slot, bee.generation or 0
      end
    elseif bee.kind == "drone" and pure_of(bee, snapshot.c) then
      p.c_drones[#p.c_drones + 1] = slot
      p.c_drone_count = p.c_drone_count + (bee.size or 1)
    end
  end
  return p
end

-- "ok", "analyze", "safety" (only the last pure drone is left) or "missing"
local function drone_status(s, species)
  local st = s.stock("drone", species)
  if st.pure >= 2 or (st.pure == 1 and not s.drone_safety) then return "ok", st.pure end
  if st.unknown > 0 then return "analyze", st.pure end
  if st.pure == 1 then return "safety", 1 end
  return "missing", 0
end

local function princess_status(s, species)
  local st = s.stock("princess", species)
  if st.pure > 0 then return "ok", st.pure end
  if st.unknown > 0 then return "analyze", 0 end
  return "missing", 0
end

local function missing_princess(s, species)
  if s.quest_mode and s.stock("princess", species).providers > 0 then
    return { action = "fail", code = "QUEST_LAST_PRINCESS", species = species }
  end
  return { action = "fail", code = "MISSING_PRINCESS", species = species }
end

local function drone_failure(status, species)
  if status == "safety" then return { action = "fail", code = "DRONE_SAFETY", species = species } end
  return { action = "fail", code = "MISSING_DRONE", species = species }
end

-- What to do when only the last pure drone of a species is left.
local function stock_up(s, species)
  if s.auto_stocking and princess_status(s, species) == "ok" then
    return { action = "stock", species = species }
  end
  return nil
end

-- Rule 6: fresh pure princess of one parent x pure drone of the other.
local function fresh_pair(s)
  local options = { { s.a, s.b } }
  if not same(s.a, s.b) then options[2] = { s.b, s.a } end
  for _, o in ipairs(options) do
    o.p_status, o.p_count = princess_status(s, o[1])
    o.d_status = drone_status(s, o[2])
  end
  local best
  for _, o in ipairs(options) do
    if o.p_status == "ok" and o.d_status == "ok" and (not best or o.p_count > best.p_count) then best = o end
  end
  if best then
    return { action = "cross", princess = { species = best[1] }, drone = { species = best[2] },
             note = "mutation with a fresh " .. best[1] .. " princess" }
  end
  for _, o in ipairs(options) do
    if o.p_status == "analyze" then return { action = "analyze", kind = "princess", species = o[1] } end
    if o.p_status == "ok" and o.d_status == "analyze" then return { action = "analyze", kind = "drone", species = o[2] } end
  end
  for _, o in ipairs(options) do
    if o.p_status == "ok" and o.d_status == "safety" then
      local step = stock_up(s, o[2])
      if step then return step end
    end
  end
  for _, o in ipairs(options) do
    if o.p_status == "ok" then return drone_failure(o.d_status, o[2]) end
  end
  return missing_princess(s, s.a)
end

-- Rule 5: the working princess with the parent drone that completes the mutation pair.
local function working_pair(s, slot, bee)
  local wanted = {}
  if carries(bee, s.a) then wanted[#wanted + 1] = s.b end
  if carries(bee, s.b) and not same(s.a, s.b) then wanted[#wanted + 1] = s.a end
  local options = {}
  for _, species in ipairs(wanted) do
    local status, count = drone_status(s, species)
    options[#options + 1] = { species = species, status = status, count = count }
  end
  table.sort(options, function(x, y) return x.count > y.count end)
  for _, o in ipairs(options) do
    if o.status == "ok" then
      return { action = "cross", princess = { slot = slot }, drone = { species = o.species },
               note = "mutation with the working princess" }
    end
  end
  for _, o in ipairs(options) do
    if o.status == "analyze" then return { action = "analyze", kind = "drone", species = o.species } end
  end
  for _, o in ipairs(options) do
    if o.status == "safety" then
      local step = stock_up(s, o.species)
      if step then return step end
    end
  end
  return nil -- try a fresh princess instead
end

-- Rules 5 and 6.
local function mutate(s, p)
  if p.working then
    local bee = s.carry[p.working]
    if carries(bee, s.a) or carries(bee, s.b) then
      local step = working_pair(s, p.working, bee)
      if step then return step end
    end
  end
  return fresh_pair(s)
end

function planner.decide(s)
  local p = planner.products(s)

  -- 1 target reached
  if #p.pure_princesses > 0 and p.c_drone_count >= s.need_drones then
    return { action = "deliver", princess = p.pure_princesses[1], drones = p.c_drones }
  end

  local c_stock = s.stock("drone", s.c)

  -- 2 more pure C drones from a pure C pair (no mutation possible)
  if #p.pure_princesses > 0 then
    if #p.c_drones > 0 then
      return { action = "cross", princess = { slot = p.pure_princesses[1] }, drone = { slot = p.c_drones[1] },
               note = "pure " .. s.c .. " pair for more drones" }
    end
    if c_stock.pure > 0 then
      return { action = "cross", princess = { slot = p.pure_princesses[1] }, drone = { species = s.c },
               note = "pure " .. s.c .. " pair with a drone from stock" }
    end
    if c_stock.unknown > 0 then return { action = "analyze", kind = "drone", species = s.c } end
    -- 3 keep the pure C princess, mutate with another princess until a pure C drone comes
    return mutate(s, p)
  end

  -- 4 recovery: pure C drones but no pure C princess
  local c_available = p.c_drone_count + c_stock.pure
  if c_available >= (s.drone_safety and 2 or 1) then
    local drone = (#p.c_drones > 0) and { slot = p.c_drones[1] } or { species = s.c }
    if p.working then
      return { action = "cross", princess = { slot = p.working }, drone = drone,
               note = "breeding back to pure " .. s.c }
    end
    for _, species in ipairs({ s.a, s.b }) do
      if princess_status(s, species) == "ok" then
        return { action = "cross", princess = { species = species }, drone = drone,
                 note = "breeding a fresh " .. species .. " princess towards " .. s.c }
      end
    end
  end

  -- 5 and 6 mutation
  return mutate(s, p)
end

return planner
