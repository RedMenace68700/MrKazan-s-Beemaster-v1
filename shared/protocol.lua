-- Message format between server and robot.
--
-- Every packet is sent as modem.send(address, port, protocol.TAG, text), where text
-- is an encoded message. Messages longer than CHUNK_SIZE travel as numbered chunks.

local serial = require("shared.serial")

local protocol = {}

protocol.VERSION = "0.1.0"
protocol.TAG = "beemasterv1"
protocol.DEFAULT_PORT = 200
-- Conservative until the real modem packet limit has been measured in game.
protocol.CHUNK_SIZE = 2048

local function is_id(value)
  return type(value) == "number" and value >= 1 and value == math.floor(value)
end

local VALIDATORS = {
  -- robot -> server: the robot program has started
  hello = function(m)
    return type(m.version) == "string"
  end,
  -- server -> robot: answer to hello
  welcome = function(m)
    return type(m.version) == "string" and type(m.accepted) == "boolean"
  end,
  -- server -> robot: one robot command
  cmd = function(m)
    return is_id(m.id) and type(m.name) == "string" and (m.args == nil or type(m.args) == "table")
  end,
  -- robot -> server: result of a robot command
  reply = function(m)
    return is_id(m.id) and type(m.ok) == "boolean" and (m.ok or type(m.err) == "string")
  end,
  -- either way: one piece of a long message
  chunk = function(m)
    return is_id(m.id) and is_id(m.part) and is_id(m.parts) and m.part <= m.parts
      and type(m.data) == "string"
  end,
  -- server -> robot: send the reply to command id again (all parts or the listed ones)
  resend = function(m)
    return is_id(m.id) and (m.parts == nil or type(m.parts) == "table")
  end,
}

function protocol.validate(msg)
  if type(msg) ~= "table" then return false end
  local check = VALIDATORS[msg.kind]
  return check ~= nil and check(msg) == true
end

function protocol.encode(msg)
  if not protocol.validate(msg) then
    error("protocol: invalid message of kind " .. tostring(type(msg) == "table" and msg.kind), 2)
  end
  return serial.encode(msg)
end

-- Returns the message, or nil plus "PROTO_BAD_MESSAGE".
function protocol.decode(text)
  local msg = serial.decode(text)
  if not protocol.validate(msg) then return nil, "PROTO_BAD_MESSAGE" end
  return msg
end

-- extra: optional table of additional fields (components, nav, ...)
function protocol.hello(version, extra)
  local msg = { kind = "hello", version = version }
  for key, value in pairs(extra or {}) do
    if msg[key] == nil then msg[key] = value end
  end
  return msg
end

function protocol.welcome(version, accepted)
  return { kind = "welcome", version = version, accepted = accepted }
end

function protocol.command(id, name, args)
  return { kind = "cmd", id = id, name = name, args = args or {} }
end

function protocol.reply_ok(id, data)
  return { kind = "reply", id = id, ok = true, data = data }
end

function protocol.reply_error(id, err, info)
  return { kind = "reply", id = id, ok = false, err = err, info = info }
end

function protocol.resend(id, parts)
  return { kind = "resend", id = id, parts = parts }
end

-- Turns an encoded message into the texts to send. A short message is sent as it is,
-- a long one is cut into chunk messages that all carry the id of the original.
function protocol.packets(id, encoded, size)
  size = size or protocol.CHUNK_SIZE
  if #encoded <= size then return { encoded } end
  local parts = math.ceil(#encoded / size)
  local packets = {}
  for part = 1, parts do
    local data = encoded:sub((part - 1) * size + 1, part * size)
    packets[part] = protocol.encode({ kind = "chunk", id = id, part = part, parts = parts, data = data })
  end
  return packets
end

-- Collects chunks until a message is complete.
local Assembler = {}
Assembler.__index = Assembler

function protocol.new_assembler()
  return setmetatable({ pending = {} }, Assembler)
end

-- Adds one chunk message. Returns the complete encoded text once all parts are there.
function Assembler:add(chunk)
  local entry = self.pending[chunk.id]
  if not entry or entry.parts ~= chunk.parts then
    entry = { parts = chunk.parts, got = {}, count = 0 }
    self.pending[chunk.id] = entry
  end
  if entry.got[chunk.part] == nil then
    entry.got[chunk.part] = chunk.data
    entry.count = entry.count + 1
  end
  if entry.count == entry.parts then
    self.pending[chunk.id] = nil
    return table.concat(entry.got, "", 1, entry.parts)
  end
  return nil
end

-- Part numbers still missing for id, or nil if nothing is pending for it.
function Assembler:missing(id)
  local entry = self.pending[id]
  if not entry then return nil end
  local missing = {}
  for part = 1, entry.parts do
    if entry.got[part] == nil then missing[#missing + 1] = part end
  end
  return missing
end

function Assembler:drop(id)
  self.pending[id] = nil
end

return protocol
