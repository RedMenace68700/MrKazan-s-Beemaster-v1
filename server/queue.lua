-- The request queue. Requests are worked on strictly in the order they were typed.
-- An entry looks like { id = 3, a = "Clay", b = "Diligent", c = "Tin" } (breed C from A
-- and B), { id = 4, c = "Iron", count = 5 } (breed a pure Iron pair 5 times), or
-- { id = 5, c = "Iron", upgrade = true } (a pure Iron princess from a basic princess).

local queue = {}

local Queue = {}
Queue.__index = Queue

-- state: table from Queue:to_table(), or nil for an empty queue.
function queue.new(state)
  state = state or {}
  local entries = {}
  for i, entry in ipairs(state.entries or {}) do
    entries[i] = { id = entry.id, a = entry.a, b = entry.b, c = entry.c, count = entry.count, upgrade = entry.upgrade }
  end
  return setmetatable({ entries = entries, next_id = state.next_id or 1 }, Queue)
end

function queue.describe(entry)
  if entry.count then
    return string.format("= %s, %d cycle(s)", entry.c, entry.count)
  end
  if entry.upgrade then return "upgrade to " .. entry.c end
  return string.format("%s + %s = %s", entry.a, entry.b, entry.c)
end

function Queue:add(request)
  local entry = { id = self.next_id, a = request.a, b = request.b, c = request.c, count = request.count, upgrade = request.upgrade }
  self.next_id = self.next_id + 1
  self.entries[#self.entries + 1] = entry
  return entry
end

-- The request that is worked on now (the first one), or nil.
function Queue:peek()
  return self.entries[1]
end

-- Removes and returns the first request, or nil.
function Queue:pop()
  return table.remove(self.entries, 1)
end

function Queue:size()
  return #self.entries
end

function Queue:list()
  local copy = {}
  for i, entry in ipairs(self.entries) do copy[i] = entry end
  return copy
end

-- Removes every request and returns how many there were.
function Queue:clear()
  local count = #self.entries
  self.entries = {}
  return count
end

function Queue:to_table()
  local entries = {}
  for i, entry in ipairs(self.entries) do
    entries[i] = { id = entry.id, a = entry.a, b = entry.b, c = entry.c, count = entry.count, upgrade = entry.upgrade }
  end
  return { entries = entries, next_id = self.next_id }
end

return queue
