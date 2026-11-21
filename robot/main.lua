-- Robot program. The EEPROM loader (robot/loader.lua) downloads it from the server
-- (bundled together with the shared modules) and calls main(modem, server, port).
--
-- The robot makes no decisions. It carries out one robot command at a time, answers
-- each one and keeps nothing but its last reply, so a repeated command is never run twice.
-- The robot only works with the inventory straight in front of it.

local protocol = require("shared.protocol")
local bees = require("shared.bees")
local grid = require("shared.grid")

local program = {}

local SIDE_DOWN, SIDE_UP, SIDE_FRONT = 0, 1, 3
-- Facing after one clockwise turn: north -> east -> south -> west -> north.
local CLOCKWISE = { [2] = 5, [5] = 3, [3] = 4, [4] = 2 }
local MOVE_TRIES = 3

local Robot = {}
Robot.__index = Robot

-- hw = { robot, ic (inventory_controller), nav (navigation or nil),
--        energy = function() return energy, max_energy end,
--        sleep = function(seconds) end, components = { names present } }
function program.new(hw)
  return setmetatable({ hw = hw, last_id = nil, last_packets = nil, chunk_size = protocol.CHUNK_SIZE }, Robot)
end

local function nav_state(hw)
  if not hw.nav then return nil end
  local state = { facing = hw.nav.getFacing() }
  local x, y, z = hw.nav.getPosition()
  if type(x) == "number" and type(y) == "number" and type(z) == "number" then
    state.x, state.y, state.z = math.floor(x), math.floor(y), math.floor(z)
  end
  return state
end

local function face(hw, direction)
  local target = grid.DIRECTIONS[direction].side
  for _ = 1, 4 do
    local current = hw.nav.getFacing()
    if current == target then return true end
    -- one counter-clockwise turn is the same as three clockwise ones
    local ccw = CLOCKWISE[CLOCKWISE[CLOCKWISE[current] or 0] or 0]
    hw.robot.turn(ccw ~= target)
  end
  return hw.nav.getFacing() == target
end

local function move_once(hw, side)
  local ok, reason
  for try = 1, MOVE_TRIES do
    ok, reason = hw.robot.move(side)
    if ok then return true end
    if try < MOVE_TRIES then hw.sleep(0.5) end
  end
  return false, reason
end

-- Reads a whole inventory. getAllStacks is one call instead of one per slot; its keys
-- start at 0 in the tested version, which is checked against getStackInSlot.
local function read_inventory(ic, side)
  local size = ic.getInventorySize(side)
  if not size then return nil end
  local slots = {}
  local ok, stacks = pcall(function() return ic.getAllStacks(side).getAll() end)
  if ok and type(stacks) == "table" then
    local offset
    for key, stack in pairs(stacks) do
      if type(stack) == "table" and stack.name then
        if offset == nil then
          local probe = ic.getStackInSlot(side, key + 1)
          offset = (probe and probe.name == stack.name) and 1 or 0
        end
        slots[key + offset] = bees.summarize(stack)
      end
    end
  else
    for slot = 1, size do
      local stack = ic.getStackInSlot(side, slot)
      if stack then slots[slot] = bees.summarize(stack) end
    end
  end
  return size, slots
end

local HANDLERS = {}

function HANDLERS.status(self)
  local hw = self.hw
  local used = 0
  for slot = 1, hw.robot.inventorySize() do
    if hw.robot.count(slot) > 0 then used = used + 1 end
  end
  local energy, max_energy = hw.energy()
  return true, {
    energy = energy, max_energy = max_energy, used = used, slots = hw.robot.inventorySize(),
    nav = nav_state(hw), version = protocol.VERSION, components = hw.components,
  }
end

function HANDLERS.move(self, args)
  local hw = self.hw
  if not hw.nav then return false, "ROBOT_COMPONENT_MISSING", { name = "navigation upgrade" } end
  local steps = args.steps or {}
  for i, step in ipairs(steps) do
    local ok, reason
    if step == "up" then
      ok, reason = move_once(hw, SIDE_UP)
    elseif step == "down" then
      ok, reason = move_once(hw, SIDE_DOWN)
    elseif grid.DIRECTIONS[step] then
      if face(hw, step) then
        ok, reason = move_once(hw, SIDE_FRONT)
      else
        ok, reason = false, "cannot turn"
      end
    else
      return false, "ROBOT_BAD_ARGS", { done = i - 1, step = step }
    end
    if not ok then
      return false, "ROBOT_BLOCKED", { done = i - 1, step = step, reason = tostring(reason), nav = nav_state(hw) }
    end
  end
  if args.face then
    if not grid.DIRECTIONS[args.face] then return false, "ROBOT_BAD_ARGS", { done = #steps, face = args.face } end
    if not face(hw, args.face) then
      return false, "ROBOT_BLOCKED", { done = #steps, reason = "cannot turn", nav = nav_state(hw) }
    end
  end
  return true, { done = #steps, nav = nav_state(hw) }
end

-- What stands in front (used by setup): inventory size and, if the game tells, its name.
function HANDLERS.probe(self)
  local ic = self.hw.ic
  local size = ic.getInventorySize(SIDE_FRONT)
  local name
  if size and ic.getInventoryName then
    local ok, result = pcall(ic.getInventoryName, SIDE_FRONT)
    if ok then name = result end
  end
  return true, { size = size or 0, name = name }
end

function HANDLERS.scan(self)
  local size, slots = read_inventory(self.hw.ic, SIDE_FRONT)
  if not size then return false, "ROBOT_NO_INVENTORY", {} end
  return true, { size = size, slots = slots }
end

function HANDLERS.inspect(self, args)
  local ic = self.hw.ic
  if not ic.getInventorySize(SIDE_FRONT) then return false, "ROBOT_NO_INVENTORY", {} end
  return true, { stack = bees.summarize(ic.getStackInSlot(SIDE_FRONT, args.slot)) }
end

-- Full stack table as the game returns it (for building test data).
function HANDLERS.dump(self, args)
  local ic = self.hw.ic
  if args.internal then return true, { stack = ic.getStackInInternalSlot(args.slot) } end
  if not ic.getInventorySize(SIDE_FRONT) then return false, "ROBOT_NO_INVENTORY", {} end
  return true, { stack = ic.getStackInSlot(SIDE_FRONT, args.slot) }
end

function HANDLERS.fetch(self, args)
  local hw = self.hw
  local ic, robot = hw.ic, hw.robot
  if type(args.slot) ~= "number" or type(args.into) ~= "number" then return false, "ROBOT_BAD_ARGS", {} end
  if not ic.getInventorySize(SIDE_FRONT) then return false, "ROBOT_NO_INVENTORY", {} end
  local stack = ic.getStackInSlot(SIDE_FRONT, args.slot)
  if not stack then return false, "ROBOT_EMPTY_SLOT", { slot = args.slot } end
  local summary = bees.summarize(stack)
  local expect = args.expect or {}
  if (expect.name and summary.name ~= expect.name)
    or (expect.species and not bees.same_species(summary.species, expect.species))
    or (expect.inactive and not bees.same_species(summary.inactive, expect.inactive)) then
    return false, "ROBOT_MISMATCH", { slot = args.slot, found = summary }
  end
  -- the target slot must be empty, or hold the same item (topping up honey)
  local before = robot.count(args.into)
  if before > 0 then
    local held = ic.getStackInInternalSlot(args.into)
    if not held or held.name ~= stack.name then return false, "ROBOT_SLOT_BUSY", { slot = args.into } end
  end
  robot.select(args.into)
  local wanted = math.min(args.count or stack.size, stack.size)
  ic.suckFromSlot(SIDE_FRONT, args.slot, wanted)
  local moved = robot.count(args.into) - before
  if moved <= 0 then return false, "ROBOT_TRANSFER_FAILED", { slot = args.slot, reason = "nothing taken" } end
  return true, {
    moved = moved,
    left = bees.summarize(ic.getStackInSlot(SIDE_FRONT, args.slot)),
    got = bees.summarize(ic.getStackInInternalSlot(args.into)),
  }
end

function HANDLERS.put(self, args)
  local hw = self.hw
  local ic, robot = hw.ic, hw.robot
  if type(args.from) ~= "number" then return false, "ROBOT_BAD_ARGS", {} end
  local item = ic.getStackInInternalSlot(args.from)
  if not item then return false, "ROBOT_EMPTY_SLOT", { slot = args.from } end
  local size, slots = read_inventory(ic, SIDE_FRONT)
  if not size then return false, "ROBOT_NO_INVENTORY", {} end
  local target = args.slot
  if target then
    if slots[target] then return false, "ROBOT_SLOT_BUSY", { slot = target } end
  else
    for slot = 1, size do
      if not slots[slot] then target = slot break end
    end
    if not target then return false, "ROBOT_CHEST_FULL", {} end
  end
  robot.select(args.from)
  local count = math.min(args.count or item.size, item.size)
  if not ic.dropIntoSlot(SIDE_FRONT, target, count) then
    return false, "ROBOT_TRANSFER_FAILED", { slot = target, reason = "drop refused" }
  end
  return true, {
    slot = target,
    stack = bees.summarize(ic.getStackInSlot(SIDE_FRONT, target)),
    left = robot.count(args.from),
  }
end

-- Puts a bee from a robot slot into the apiary: a princess (or queen) into the queen
-- slot, exactly one drone into the drone slot. side is absolute (4 = west).
-- Whatever was in that apiary slot before comes back into the robot slot ("back").
function HANDLERS.insert(self, args)
  local hw = self.hw
  if not hw.beekeeper then return false, "ROBOT_COMPONENT_MISSING", { name = "beekeeper upgrade" } end
  if type(args.from) ~= "number" or type(args.side) ~= "number" then return false, "ROBOT_BAD_ARGS", {} end
  local item = hw.ic.getStackInInternalSlot(args.from)
  if not item then return false, "ROBOT_EMPTY_SLOT", { slot = args.from } end
  local summary = bees.summarize(item)
  local queen_slot = args.kind == "princess" or args.kind == "queen"
  local expect = args.expect or {}
  if summary.kind ~= args.kind or (expect.species and not bees.same_species(summary.species, expect.species)) then
    return false, "ROBOT_MISMATCH", { slot = args.from, found = summary }
  end
  if not queen_slot and item.size ~= 1 then
    return false, "ROBOT_BAD_ARGS", { reason = "exactly one drone", size = item.size }
  end
  hw.robot.select(args.from)
  local ok, reason
  if queen_slot then
    ok, reason = hw.beekeeper.swapQueen(args.side)
  else
    ok, reason = hw.beekeeper.swapDrone(args.side)
  end
  local back = bees.summarize(hw.ic.getStackInInternalSlot(args.from))
  if not ok then
    return false, "ROBOT_TRANSFER_FAILED", { reason = tostring(reason or "swap refused"), back = back }
  end
  return true, { back = back }
end

-- Analyzes the bee in a robot slot, paying with honey from honey_slot.
function HANDLERS.analyze(self, args)
  local hw = self.hw
  if not hw.beekeeper then return false, "ROBOT_COMPONENT_MISSING", { name = "beekeeper upgrade" } end
  local item = hw.ic.getStackInInternalSlot(args.slot)
  if not item then return false, "ROBOT_EMPTY_SLOT", { slot = args.slot } end
  if not bees.kind(item.name) then return false, "ROBOT_MISMATCH", { slot = args.slot, found = bees.summarize(item) } end
  hw.robot.select(args.slot)
  local ok, reason = hw.beekeeper.analyze(args.honey)
  if not ok then
    if tostring(reason):lower():find("honey", 1, true) then return false, "NO_HONEY", {} end
    return false, "ROBOT_TRANSFER_FAILED", { reason = tostring(reason) }
  end
  return true, { bee = bees.summarize(hw.ic.getStackInInternalSlot(args.slot)), honey = hw.robot.count(args.honey) }
end

-- Moves count items from one robot slot into an empty one (e.g. one drone off a stack).
function HANDLERS.split(self, args)
  local robot = self.hw.robot
  if type(args.from) ~= "number" or type(args.to) ~= "number" or type(args.count) ~= "number" then
    return false, "ROBOT_BAD_ARGS", {}
  end
  if robot.count(args.from) < args.count then return false, "ROBOT_EMPTY_SLOT", { slot = args.from } end
  if robot.count(args.to) > 0 then return false, "ROBOT_SLOT_BUSY", { slot = args.to } end
  robot.select(args.from)
  if not robot.transferTo(args.to, args.count) then
    return false, "ROBOT_TRANSFER_FAILED", { reason = "transfer refused" }
  end
  local ic = self.hw.ic
  return true, {
    from = bees.summarize(ic.getStackInInternalSlot(args.from)),
    to = bees.summarize(ic.getStackInInternalSlot(args.to)),
  }
end

function HANDLERS.inventory(self)
  local hw = self.hw
  local slots = {}
  for slot = 1, hw.robot.inventorySize() do
    if hw.robot.count(slot) > 0 then
      slots[slot] = bees.summarize(hw.ic.getStackInInternalSlot(slot))
    end
  end
  return true, { size = hw.robot.inventorySize(), slots = slots }
end

function Robot:execute(cmd)
  local handler = HANDLERS[cmd.name]
  if not handler then return protocol.reply_error(cmd.id, "ROBOT_UNKNOWN_COMMAND", { name = cmd.name }) end
  local traceback = debug and debug.traceback or tostring
  local ok, good, data, info = xpcall(handler, traceback, self, cmd.args or {})
  if not ok then return protocol.reply_error(cmd.id, "ROBOT_INTERNAL", { text = tostring(good), command = cmd.name }) end
  if good then return protocol.reply_ok(cmd.id, data) end
  return protocol.reply_error(cmd.id, data, info)
end

local function encode_reply(reply)
  local ok, text = pcall(protocol.encode, reply)
  if ok then return text end
  return protocol.encode(protocol.reply_error(reply.id, "ROBOT_INTERNAL", { text = tostring(text) }))
end

-- Handles one received text and returns the packets to send back.
function Robot:receive(text)
  local msg = protocol.decode(text)
  if not msg then return {} end
  if msg.kind == "cmd" then
    if msg.id == self.last_id then return self.last_packets end
    if self.last_id and msg.id < self.last_id then
      -- a late copy of an old command, or a restarted server counting from 1 again
      return { encode_reply(protocol.reply_error(msg.id, "ROBOT_STALE_ID", { last = self.last_id })) }
    end
    local reply = self:execute(msg)
    self.last_id = msg.id
    self.last_packets = protocol.packets(msg.id, encode_reply(reply), self.chunk_size)
    return self.last_packets
  elseif msg.kind == "resend" then
    if msg.id ~= self.last_id then return {} end
    if not msg.parts then return self.last_packets end
    local out = {}
    for _, part in ipairs(msg.parts) do out[#out + 1] = self.last_packets[part] end
    return out
  end
  return {}
end

function Robot:hello()
  return protocol.encode(protocol.hello(protocol.VERSION, {
    components = self.hw.components, nav = nav_state(self.hw),
  }))
end

-- Builds hw from the real components (only on a robot).
function program.hardware()
  local function proxy(name)
    local address = component.list(name)()
    return address and component.proxy(address)
  end
  local present = {}
  for _, name in ipairs({ "inventory_controller", "navigation", "beekeeper" }) do
    if component.list(name)() then present[#present + 1] = name end
  end
  return {
    robot = proxy("robot"),
    ic = proxy("inventory_controller"),
    nav = proxy("navigation"),
    beekeeper = proxy("beekeeper"),
    components = present,
    energy = function() return computer.energy(), computer.maxEnergy() end,
    -- waits without losing network messages that arrive meanwhile
    sleep = function(seconds)
      local deadline = computer.uptime() + seconds
      local kept = {}
      while computer.uptime() < deadline do
        local signal = table.pack(computer.pullSignal(deadline - computer.uptime()))
        if signal[1] then kept[#kept + 1] = signal end
      end
      for _, signal in ipairs(kept) do computer.pushSignal(table.unpack(signal, 1, signal.n)) end
    end,
  }
end

-- Entry point on the robot.
function program.main(modem, server, port)
  local robot = program.new(program.hardware())
  modem.open(port)
  local function send(text) modem.send(server, port, protocol.TAG, text) end
  local function from_server(signal)
    return signal[1] == "modem_message" and signal[3] == server and signal[4] == port
      and signal[6] == protocol.TAG and type(signal[7]) == "string"
  end

  -- say hello until the server answers
  local welcomed = false
  while not welcomed do
    send(robot:hello())
    local deadline = computer.uptime() + 3
    while not welcomed and computer.uptime() < deadline do
      local signal = table.pack(computer.pullSignal(deadline - computer.uptime()))
      if from_server(signal) then
        local msg = protocol.decode(signal[7])
        if msg and msg.kind == "welcome" then
          if not msg.accepted then
            -- wrong version: stay idle, a reboot loads the server's current program
            while true do computer.pullSignal() end
          end
          welcomed = true
        end
      end
    end
  end

  while true do
    local signal = table.pack(computer.pullSignal())
    if from_server(signal) then
      if signal[7] == "where" then
        send(robot:hello())
      else
        for _, packet in ipairs(robot:receive(signal[7])) do send(packet) end
      end
    end
  end
end

return program
