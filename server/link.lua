-- Connection to the robot: handshake, numbered commands with retries, chunked replies,
-- and serving the robot program to the EEPROM loader.
--
-- Independent of OpenOS: the main program passes in functions to send packets and to
-- read the clock, feeds received packets into handle() and calls poll() regularly.
-- What happens is reported as events (see take_events).

local protocol = require("shared.protocol")

local link = {}

local Link = {}
Link.__index = Link

-- opts:
--   send(address, ...)   send one packet (all values after the port)
--   broadcast(...)       send one packet to everyone
--   now()                clock in seconds
--   code()               robot program text, or nil plus an error text
--   timeout, retries, chunk_size
function link.new(opts)
  return setmetatable({
    send_raw = opts.send,
    broadcast_raw = opts.broadcast,
    now = opts.now,
    code = opts.code,
    timeout = opts.timeout or 5,
    retries = opts.retries or 6,
    chunk_size = opts.chunk_size or protocol.CHUNK_SIZE,
    robot = nil,
    info = nil,
    next_id = 1,
    pending = nil,
    assembler = protocol.new_assembler(),
    events = {},
  }, Link)
end

function Link:emit(event)
  self.events[#self.events + 1] = event
end

-- Returns and clears the events since the last call:
--   { type = "hello", address, info }      robot connected (info = hello message)
--   { type = "version", address, version } robot runs another version, not accepted
--   { type = "boot", address, size }       a loader asked for the robot program
--   { type = "boot_failed", address, error }
--   { type = "crash", address, text }      the robot program crashed
--   { type = "reply", id, reply }          answer to call(id); may be a local error reply
--   { type = "bad_message", address }
function Link:take_events()
  local events = self.events
  self.events = {}
  return events
end

function Link:connected()
  return self.robot ~= nil
end

function Link:busy()
  return self.pending ~= nil
end

-- Asks a robot that is already running (e.g. after a server restart) to say hello.
function Link:discover()
  self.broadcast_raw(protocol.TAG, "where")
end

local function error_reply(id, code, info)
  return { kind = "reply", id = id, ok = false, err = code, info = info or {} }
end

function Link:fail_pending(code)
  local p = self.pending
  if not p then return end
  self.pending = nil
  self.assembler:drop(p.wire_id)
  self:emit({ type = "reply", id = p.call_id, reply = error_reply(p.call_id, code, { id = p.call_id, name = p.name }) })
end

-- Forgets a pending command without an event (its task is gone). A late reply to it is
-- ignored because ids only ever grow.
function Link:abandon()
  if self.pending then self.assembler:drop(self.pending.wire_id) end
  self.pending = nil
end

-- The robot is gone (rebooting or crashed): a pending command cannot finish.
function Link:lost()
  self.robot = nil
  self:fail_pending("ROBOT_RESTARTED")
end

function Link:transmit()
  local p = self.pending
  p.tries = p.tries + 1
  p.sent = self.now()
  for _, packet in ipairs(protocol.packets(p.wire_id, p.text, self.chunk_size)) do
    self.send_raw(self.robot, protocol.TAG, packet)
  end
end

-- Sends a robot command. Returns the id that the reply event will carry, or nil plus
-- "ROBOT_NOT_CONNECTED". Only one command can be pending at a time.
function Link:call(name, args)
  if not self.robot then return nil, "ROBOT_NOT_CONNECTED" end
  if self.pending then error("link: a command is already pending", 2) end
  local id = self.next_id
  self.next_id = id + 1
  self.pending = { call_id = id, wire_id = id, name = name, args = args or {}, tries = 0 }
  self.pending.text = protocol.encode(protocol.command(id, name, args or {}))
  self:transmit()
  return id
end

function Link:serve_code(address)
  local text, err = self.code()
  if not text then
    self:emit({ type = "boot_failed", address = address, error = err })
    return
  end
  if address == self.robot then self:lost() end
  local size = self.chunk_size
  local total = math.max(1, math.ceil(#text / size))
  for i = 1, total do
    self.send_raw(address, protocol.TAG, "code", i, total, text:sub((i - 1) * size + 1, i * size))
  end
  self:emit({ type = "boot", address = address, size = #text })
end

function Link:accept_reply(reply)
  local p = self.pending
  if not p or reply.id ~= p.wire_id then return end -- late copy of an old reply
  if not reply.ok and reply.err == "ROBOT_STALE_ID" and type(reply.info) == "table"
    and type(reply.info.last) == "number" then
    -- The robot already saw higher ids (the server was restarted): continue above them.
    self.next_id = math.max(self.next_id, reply.info.last + 1)
    p.wire_id = self.next_id
    self.next_id = self.next_id + 1
    p.text = protocol.encode(protocol.command(p.wire_id, p.name, p.args))
    self:transmit()
    return
  end
  self.pending = nil
  self:emit({ type = "reply", id = p.call_id, reply = reply })
end

function Link:handle_message(from, msg)
  if msg.kind == "hello" then
    local accepted = msg.version == protocol.VERSION
    self.send_raw(from, protocol.TAG, protocol.encode(protocol.welcome(protocol.VERSION, accepted)))
    -- a hello while a command is pending means the robot program started again
    if from == self.robot and self.pending then self:fail_pending("ROBOT_RESTARTED") end
    if accepted then
      self.robot = from
      self.info = msg
      self:emit({ type = "hello", address = from, info = msg })
    else
      self:emit({ type = "version", address = from, version = msg.version })
    end
    return
  end
  if from ~= self.robot then return end
  if msg.kind == "chunk" then
    local text = self.assembler:add(msg)
    if text then
      local full = protocol.decode(text)
      if full and full.kind == "reply" then self:accept_reply(full) end
    end
  elseif msg.kind == "reply" then
    self:accept_reply(msg)
  end
end

-- Feeds one received packet: from = sender address, then the values after the port
-- (tag first). Packets with another tag are ignored.
function Link:handle(from, tag, first, ...)
  if tag ~= protocol.TAG then return end
  if first == "boot" then return self:serve_code(from) end
  if first == "crash" then
    self:emit({ type = "crash", address = from, text = tostring((...)) })
    if from == self.robot then self:lost() end
    return
  end
  if type(first) ~= "string" then return end
  local msg = protocol.decode(first)
  if not msg then
    self:emit({ type = "bad_message", address = from })
    return
  end
  self:handle_message(from, msg)
end

-- Resends or gives up on a pending command whose reply is overdue.
function Link:poll()
  local p = self.pending
  if not p or self.now() - p.sent < self.timeout then return end
  if p.tries > self.retries then
    self:fail_pending("ROBOT_TIMEOUT")
    return
  end
  local missing = self.assembler:missing(p.wire_id)
  if missing and #missing > 0 then
    p.tries = p.tries + 1
    p.sent = self.now()
    self.send_raw(self.robot, protocol.TAG, protocol.encode(protocol.resend(p.wire_id, missing)))
  else
    self:transmit()
  end
end

return link
