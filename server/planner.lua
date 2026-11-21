-- Decides the next step of a request A + B = C. Pure logic on a snapshot, no robot.
--
-- How Forestry breeds: the mutation is rolled separately for the princess's side and the
-- drone's side of each offspring. One mutated side gives a hybrid that carries C (X/C);
-- a pure C bee needs both sides. So hybrids carrying C come far more often than pure C
-- bees, and the fastest way to a pure C pair is to cross C carriers with each other:
--   X/C x pure C -> 1/2 pure C,  X/C x X/C -> 1/4 pure C,  mutating again -> about p*p.
--
-- The products of a request (its princesses and the drones carrying C) stay in the robot
-- until they are delivered; everything else goes back into the chests.
--
-- snapshot = {
--   a, b, c,                        species of the request
--   carry = { [slot] = summary },   products the robot carries (honey excluded)
--   stock(kind, species) -> { pure = n, unknown = n, carriers = n, providers = n }
--       in the allowed chests: known pure, not yet analyzed, carrying the species but not
--       known pure (hybrids, or unread bees showing it as active species), and
--       (QuestMode) pure ones only in the provider chests
--   need_drones,                    1 (single_pair) or SpareDrones (extra_spares)
--   drone_safety, auto_stocking, quest_mode
-- }
--
-- Rules (the first that applies wins):
--   1 target reached: deliver
--   2 a pure C princess: x pure C drone (C x C), else analyze unread C drones, else
--     x drone carrying C (half the offspring pure C)
--   3 the best princess carrying C (carried, else a hybrid from stock) x the best drone
--     carrying C (pure before hybrid)
--   4 a princess without C x the best drone carrying C (her offspring then carry C)
--   5 no C drone anywhere: mutation, working princess x the parent drone she is missing
--   6 mutation with a fresh pure parent princess from stock
-- Steps:
--   { action = "deliver", princess = slot, drones = { slot, ... } }
--   { action = "cross", princess = source, drone = source, note = text }
--       source = { slot = n } (carried), { species = "X" } (pure one from stock),
--                { carrier = "X" } (one from stock carrying X, not known pure)
--   { action = "analyze", kind = "princess"|"drone", species = "X" }
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

-- Sorts the carried products:
--   pure_princesses   pure C princesses
--   c_princess        newest princess carrying C (not pure)
--   working           newest princess without C
--   c_drones          pure C drones, c_drone_count their number
--   hybrid_drones     drones carrying C, not pure
function planner.products(snapshot)
  local p = { pure_princesses = {}, c_drones = {}, c_drone_count = 0, hybrid_drones = {} }
  local slots = {}
  for slot in pairs(snapshot.carry) do slots[#slots + 1] = slot end
  table.sort(slots)
  local generation = {}
  local function newest(field, slot, bee)
    local g = bee.generation or 0
    if not p[field] or g > generation[field] then p[field], generation[field] = slot, g end
  end
  for _, slot in ipairs(slots) do
    local bee = snapshot.carry[slot]
    if bee.kind == "princess" then
      if pure_of(bee, snapshot.c) then
        p.pure_princesses[#p.pure_princesses + 1] = slot
      elseif carries(bee, snapshot.c) then
        newest("c_princess", slot, bee)
      else
        newest("working", slot, bee)
      end
    elseif bee.kind == "drone" and pure_of(bee, snapshot.c) then
      p.c_drones[#p.c_drones + 1] = slot
      p.c_drone_count = p.c_drone_count + (bee.size or 1)
    elseif bee.kind == "drone" and carries(bee, snapshot.c) then
      p.hybrid_drones[#p.hybrid_drones + 1] = slot
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

local function stock_up(s, species)
  if s.auto_stocking and princess_status(s, species) == "ok" then
    return { action = "stock", species = species }
  end
  return nil
end

-- A parent drone for a mutation from stock: a pure one (DroneSafetyMode keeps the last),
-- else a hybrid carrying the species. Unread drones are looked at first, they may be pure.
-- Returns source, "pure"/"hybrid" or nil, "analyze"/"safety"/"missing".
local function parent_drone(s, species)
  local status = drone_status(s, species)
  if status == "ok" then return { species = species }, "pure" end
  if status == "analyze" then return nil, "analyze" end
  if s.stock("drone", species).carriers > 0 then return { carrier = species }, "hybrid" end
  return nil, status
end

-- A parent princess from stock: a pure one, else a hybrid carrying the species.
-- Returns source, "pure"/"hybrid", number of pure ones, or nil, "analyze"/"missing".
local function parent_princess(s, species)
  local status, count = princess_status(s, species)
  if status == "ok" then return { species = species }, "pure", count end
  if status == "analyze" then return nil, "analyze", 0 end
  if s.stock("princess", species).carriers > 0 then return { carrier = species }, "hybrid", 0 end
  return nil, "missing", 0
end

-- Rule 6: a fresh princess of one parent x a drone of the other. Pure bees mutate twice
-- as often as hybrids, so pure ones come first; hybrids carrying the parent species are
-- the fallback when pure ones are missing or protected.
local function fresh_pair(s)
  local options = { { s.a, s.b } }
  if not same(s.a, s.b) then options[2] = { s.b, s.a } end
  for _, o in ipairs(options) do
    o.princess, o.p_kind, o.p_count = parent_princess(s, o[1])
    o.drone, o.d_kind = parent_drone(s, o[2])
    o.score = (o.p_kind == "pure" and 2 or 0) + (o.d_kind == "pure" and 2 or 0) + o.p_count / 1000
  end
  local best
  for _, o in ipairs(options) do
    if o.princess and o.drone and (not best or o.score > best.score) then best = o end
  end
  if best then
    local note = "mutation with a fresh " .. best[1] .. " princess"
    if best.p_kind == "hybrid" then note = "mutation with a hybrid princess carrying " .. best[1] end
    if best.d_kind == "hybrid" then note = note .. " and a hybrid drone carrying " .. best[2] end
    return { action = "cross", princess = best.princess, drone = best.drone, note = note }
  end
  for _, o in ipairs(options) do
    if o.p_kind == "analyze" then return { action = "analyze", kind = "princess", species = o[1] } end
    if o.princess and o.d_kind == "analyze" then return { action = "analyze", kind = "drone", species = o[2] } end
  end
  for _, o in ipairs(options) do
    if o.princess and o.d_kind == "safety" then
      local step = stock_up(s, o[2])
      if step then return step end
    end
  end
  for _, o in ipairs(options) do
    if o.princess then return drone_failure(o.d_kind, o[2]) end
  end
  return missing_princess(s, s.a)
end

-- Rule 5: a princess with the parent drone that completes the mutation pair
-- (pure drones first, then hybrids carrying the species).
local function working_pair(s, slot, bee)
  local options = {}
  local function consider(species)
    local source, kind = parent_drone(s, species)
    options[#options + 1] = { species = species, source = source, kind = kind,
                              count = s.stock("drone", species).pure }
  end
  if carries(bee, s.a) then consider(s.b) end
  if carries(bee, s.b) and not same(s.a, s.b) then consider(s.a) end
  table.sort(options, function(x, y)
    if (x.kind == "pure") ~= (y.kind == "pure") then return x.kind == "pure" end
    return x.count > y.count
  end)
  for _, o in ipairs(options) do
    if o.source then
      local note = "mutation with the working princess"
      if o.kind == "hybrid" then note = note .. " and a hybrid drone carrying " .. o.species end
      return { action = "cross", princess = { slot = slot }, drone = o.source, note = note }
    end
  end
  for _, o in ipairs(options) do
    if o.kind == "analyze" then return { action = "analyze", kind = "drone", species = o.species } end
  end
  for _, o in ipairs(options) do
    if o.kind == "safety" then
      local step = stock_up(s, o.species)
      if step then return step end
    end
  end
  return nil
end

-- Rules 5 and 6. `princess` is the carried princess to mutate with, if any.
local function mutate(s, slot)
  if slot then
    local bee = s.carry[slot]
    if carries(bee, s.a) or carries(bee, s.b) then
      local step = working_pair(s, slot, bee)
      if step then return step end
    end
  end
  return fresh_pair(s)
end

-- The best drone carrying C for a princess that is not pure C, or nil.
-- Pure C drones respect DroneSafetyMode (the last one only goes with a pure C princess).
local function c_drone(s, p, c_stock)
  local pure_total = p.c_drone_count + c_stock.pure
  if pure_total >= 2 or (pure_total == 1 and not s.drone_safety) then
    if #p.c_drones > 0 then return { slot = p.c_drones[1] }, "pure" end
    return { species = s.c }, "pure"
  end
  if #p.hybrid_drones > 0 then return { slot = p.hybrid_drones[1] }, "hybrid" end
  if c_stock.carriers > 0 then return { carrier = s.c }, "hybrid" end
  return nil
end

function planner.decide(s)
  local p = planner.products(s)
  local c = s.c

  -- 1 target reached
  if #p.pure_princesses > 0 and p.c_drone_count >= s.need_drones then
    return { action = "deliver", princess = p.pure_princesses[1], drones = p.c_drones }
  end

  local c_stock = s.stock("drone", c)

  -- 2 a pure C princess
  if #p.pure_princesses > 0 then
    local princess = { slot = p.pure_princesses[1] }
    if #p.c_drones > 0 then
      return { action = "cross", princess = princess, drone = { slot = p.c_drones[1] },
               note = "pure " .. c .. " pair for more drones" }
    end
    if c_stock.pure > 0 then
      return { action = "cross", princess = princess, drone = { species = c },
               note = "pure " .. c .. " pair with a drone from stock" }
    end
    if c_stock.unknown > 0 then return { action = "analyze", kind = "drone", species = c } end
    local drone = (#p.hybrid_drones > 0) and { slot = p.hybrid_drones[1] }
      or (c_stock.carriers > 0 and { carrier = c }) or nil
    if drone then
      return { action = "cross", princess = princess, drone = drone,
               note = "pure " .. c .. " princess with a " .. c .. " hybrid drone" }
    end
    return mutate(s, p.c_princess or p.working)
  end

  -- 3 and 4: cross with a drone carrying C
  local drone, drone_kind = c_drone(s, p, c_stock)
  if drone then
    if p.c_princess then
      return { action = "cross", princess = { slot = p.c_princess }, drone = drone,
               note = c .. " carriers together (" .. drone_kind .. " drone)" }
    end
    if s.stock("princess", c).carriers > 0 then
      return { action = "cross", princess = { carrier = c }, drone = drone,
               note = c .. " carriers together, princess from stock" }
    end
    if p.working then
      return { action = "cross", princess = { slot = p.working }, drone = drone,
               note = "bringing " .. c .. " into the working princess" }
    end
    for _, species in ipairs({ s.a, s.b }) do
      if princess_status(s, species) == "ok" then
        return { action = "cross", princess = { species = species }, drone = drone,
                 note = "bringing " .. c .. " into a fresh " .. species .. " princess" }
      end
    end
  end

  -- a princess carrying C but no drone carrying C: she can still mutate
  return mutate(s, p.c_princess or p.working)
end

return planner
