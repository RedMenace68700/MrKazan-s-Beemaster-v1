-- The inventory: what the server believes lies in which chest slot.
--
-- Chests are keyed by position id ("5/1" = field 5, height 1). Each chest holds its
-- size, the time of its last scan and a map slot -> bee summary (see shared/bees.lua).
-- Chests are not sorted by species; the ledger only remembers where everything is.
--
-- The inventory is trusted. Before the robot takes a bee it checks the slot; if the slot
-- holds something else, that one chest is scanned again (see Ledger:locate).

local bees = require("shared.bees")

local ledger = {}

local Ledger = {}
Ledger.__index = Ledger

-- state: table from Ledger:to_table(), or nil for an empty inventory.
function ledger.new(state)
  return setmetatable({ chests = (state and state.chests) or {} }, Ledger)
end

-- filter fields (all optional):
--   name, kind ("princess"/"drone"/"queen"), species (active species),
--   carries (active or, if analyzed, inactive species), not_pure (anything but known pure),
--   species_in (set of lower-case names: the active species is one of them),
--   all_in (set: analyzed, and both active and inactive species are in it),
--   pure (true = known pure, false = known hybrid), natural (true = isNatural required),
--   analyzed (true/false)
function ledger.matches(summary, filter)
  if type(summary) ~= "table" then return false end
  if filter.name and summary.name ~= filter.name then return false end
  if filter.kind and summary.kind ~= filter.kind then return false end
  if filter.species and not bees.same_species(summary.species, filter.species) then return false end
  if filter.carries and not (bees.same_species(summary.species, filter.carries)
    or bees.same_species(summary.inactive, filter.carries)) then return false end
  if filter.not_pure and bees.purity(summary) == true then return false end
  if filter.species_in and not filter.species_in[tostring(summary.species):lower()] then return false end
  if filter.all_in and not (summary.analyzed and filter.all_in[tostring(summary.species):lower()]
    and filter.all_in[tostring(summary.inactive):lower()]) then return false end
  if filter.pure ~= nil and bees.purity(summary) ~= filter.pure then return false end
  if filter.natural and summary.natural ~= true then return false end
  if filter.analyzed ~= nil and summary.analyzed ~= filter.analyzed then return false end
  return true
end

-- Replaces everything known about one chest with a fresh scan.
function Ledger:set_chest(id, size, slots, time)
  self.chests[id] = { size = size, slots = slots or {}, scanned = time }
end

function Ledger:chest(id)
  return self.chests[id]
end

function Ledger:forget(id)
  self.chests[id] = nil
end

-- Updates one slot from a robot reply (summary or nil for an empty slot).
-- Returns false if the chest is unknown.
function Ledger:set_slot(id, slot, summary)
  local chest = self.chests[id]
  if not chest then return false end
  chest.slots[slot] = summary
  return true
end

function Ledger:get_slot(id, slot)
  local chest = self.chests[id]
  return chest and chest.slots[slot]
end

function Ledger:free_slots(id)
  local chest = self.chests[id]
  if not chest then return 0 end
  local used = 0
  for _ in pairs(chest.slots) do used = used + 1 end
  return chest.size - used
end

function Ledger:first_free_slot(id)
  local chest = self.chests[id]
  if not chest then return nil end
  for slot = 1, chest.size do
    if chest.slots[slot] == nil then return slot end
  end
  return nil
end

-- All matching slots as { chest = id, slot = n, bee = summary }, following the chest
-- order given (list of ids) and slot numbers within a chest.
function Ledger:find(filter, order)
  local found = {}
  for _, id in ipairs(order) do
    local chest = self.chests[id]
    if chest then
      for slot = 1, chest.size do
        local summary = chest.slots[slot]
        if summary and ledger.matches(summary, filter) then
          found[#found + 1] = { chest = id, slot = slot, bee = summary }
        end
      end
    end
  end
  return found
end

-- Number of matching items (stack sizes added up).
function Ledger:count(filter, order)
  local total = 0
  for _, hit in ipairs(self:find(filter, order)) do
    total = total + (hit.bee.size or 1)
  end
  return total
end

-- Finds a matching bee and makes sure it is really there.
--   actions.verify(hit) -> true if the slot really holds the bee
--   actions.rescan(chest_id) -> scans that chest again and calls set_chest
-- If the slot is wrong, the chest is rescanned once and the search starts again.
-- If a freshly scanned chest is still wrong (e.g. an ME system moved items in between),
-- that slot is marked empty. Returns the confirmed hit, or nil if nothing matches.
function Ledger:locate(filter, order, actions)
  local rescanned = {}
  while true do
    local hit = self:find(filter, order)[1]
    if not hit then return nil end
    if actions.verify(hit) then return hit end
    if rescanned[hit.chest] then
      self:set_slot(hit.chest, hit.slot, nil)
    else
      rescanned[hit.chest] = true
      actions.rescan(hit.chest)
    end
  end
end

function Ledger:to_table()
  return { chests = self.chests }
end

return ledger
