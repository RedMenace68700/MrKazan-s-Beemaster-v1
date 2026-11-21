-- The fixed 4 x 5 grid the program is built for.
--
-- Fields are numbered 1..20 row by row. A field is also a cell (x, y) with
-- x = column 1..4 and y = row 1..5. Top of the drawing is south, right is west.
-- Heights are 1..3, height 1 is the level the robot drives on.
-- Directions are real Minecraft compass directions, so their side numbers match the
-- absolute sides used by the beekeeper upgrade.

local grid = {}

grid.COLUMNS = 4
grid.ROWS = 5
grid.MAX_HEIGHT = 3

grid.DIRECTIONS = {
  west = { dx = 1, dy = 0, side = 4 },
  east = { dx = -1, dy = 0, side = 5 },
  north = { dx = 0, dy = 1, side = 2 },
  south = { dx = 0, dy = -1, side = 3 },
}
-- Fixed order so paths are always the same.
local DIRECTION_ORDER = { "north", "south", "west", "east" }

-- Home: the charger on field 6.
grid.HOME = { x = 2, y = 2, h = 1 }

local WALKABLE = { "2,2", "2,3", "2,4", "3,2", "3,3" }
local walkable = {}
for _, key in ipairs(WALKABLE) do walkable[key] = true end

function grid.is_walkable(x, y)
  return walkable[x .. "," .. y] == true
end

function grid.field_to_cell(field)
  local index = field - 1
  return index % grid.COLUMNS + 1, math.floor(index / grid.COLUMNS) + 1
end

function grid.cell_to_field(x, y)
  return (y - 1) * grid.COLUMNS + x
end

-- Every place where a component may stand, and the robot cell and facing from which
-- the robot reaches it (always straight in front, at the same height).
local PLACES = {
  { field = 2,  role = "provider", heights = { 1, 2, 3 }, required = { 1 }, from = { 2, 2 }, facing = "south" },
  { field = 5,  role = "supply",   heights = { 1, 2, 3 }, required = {},    from = { 2, 2 }, facing = "east" },
  { field = 9,  role = "supply",   heights = { 1, 2, 3 }, required = {},    from = { 2, 3 }, facing = "east" },
  { field = 13, role = "supply",   heights = { 1, 2, 3 }, required = {},    from = { 2, 4 }, facing = "east" },
  { field = 18, role = "supply",   heights = { 1, 2, 3 }, required = {},    from = { 2, 4 }, facing = "north" },
  { field = 15, role = "honey",    heights = { 1 },       required = { 1 }, from = { 3, 3 }, facing = "north" },
  { field = 12, role = "apiary",   heights = { 1 },       required = { 1 }, from = { 3, 3 }, facing = "west" },
  { field = 12, role = "output",   heights = { 2 },       required = { 2 }, from = { 3, 3 }, facing = "west" },
}

local positions, by_id = {}, {}
for _, place in ipairs(PLACES) do
  local required = {}
  for _, h in ipairs(place.required) do required[h] = true end
  for _, h in ipairs(place.heights) do
    local position = {
      id = place.field .. "/" .. h,
      field = place.field,
      height = h,
      role = place.role,
      required = required[h] == true,
      x = place.from[1],
      y = place.from[2],
      facing = place.facing,
    }
    positions[#positions + 1] = position
    by_id[position.id] = position
  end
end

-- All positions in a fixed order: provider, supply (field by field, bottom up),
-- honey, apiary, output. Callers must not modify the returned tables.
function grid.positions()
  return positions
end

-- Position by id such as "5/2" (field 5, height 2), or nil.
function grid.position(id)
  return by_id[id]
end

-- Horizontal path between two walkable cells as a list of directions, or nil.
function grid.path(fx, fy, tx, ty)
  if not (grid.is_walkable(fx, fy) and grid.is_walkable(tx, ty)) then return nil end
  local start, goal = fx .. "," .. fy, tx .. "," .. ty
  local previous = { [start] = false }
  local queue, head = { { fx, fy } }, 1
  while head <= #queue do
    local cx, cy = queue[head][1], queue[head][2]
    head = head + 1
    if cx == tx and cy == ty then break end
    for _, name in ipairs(DIRECTION_ORDER) do
      local d = grid.DIRECTIONS[name]
      local nx, ny = cx + d.dx, cy + d.dy
      local key = nx .. "," .. ny
      if walkable[key] and previous[key] == nil then
        previous[key] = { x = cx, y = cy, dir = name }
        queue[#queue + 1] = { nx, ny }
      end
    end
  end
  if previous[goal] == nil then return nil end
  local steps = {}
  local key = goal
  while previous[key] do
    table.insert(steps, 1, previous[key].dir)
    key = previous[key].x .. "," .. previous[key].y
  end
  return steps
end

-- Steps from a robot position {x, y, h} to a target {x, y, h or height}.
-- The robot only drives horizontally at height 1: it goes down first and up at the end.
function grid.route(from, to)
  local target_h = to.h or to.height or 1
  local steps = {}
  if from.x == to.x and from.y == to.y then
    for _ = from.h + 1, target_h do steps[#steps + 1] = "up" end
    for _ = target_h + 1, from.h do steps[#steps + 1] = "down" end
    return steps
  end
  local flat = grid.path(from.x, from.y, to.x, to.y)
  if not flat then return nil end
  for _ = 2, from.h do steps[#steps + 1] = "down" end
  for _, dir in ipairs(flat) do steps[#steps + 1] = dir end
  for _ = 2, target_h do steps[#steps + 1] = "up" end
  return steps
end

return grid
