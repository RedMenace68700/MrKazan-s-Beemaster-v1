-- Runs one task at a time (setup, a breeding run, ...) as a coroutine, so tasks can be
-- written step by step while the main loop keeps handling keyboard and network.
--
-- A task is a function(ctx) that returns a result table:
--   { ok = true/false, error = error object, lines = { text, ... }, stopped = true }
-- Inside a task, ctx.call / ctx.sleep / ctx.stopping come from this runner.

local errors = require("server.errors")

local runner = {}

local Runner = {}
Runner.__index = Runner

-- link: server/link.lua object; now: clock function in seconds
function runner.new(link, now)
  return setmetatable({ link = link, now = now, co = nil, finished = {} }, Runner)
end

function Runner:busy()
  return self.co ~= nil
end

function Runner:current()
  return self.name
end

-- Asks the running task to end at its next safe point.
function Runner:request_stop()
  if self.co then self.stop = true end
end

-- For tasks: send a robot command and wait for its reply.
function Runner:call(name, args)
  local id, err = self.link:call(name, args)
  if not id then return { ok = false, err = err, info = {} } end
  return coroutine.yield({ wait = id })
end

-- For tasks: wait without blocking the server.
function Runner:sleep(seconds)
  coroutine.yield({ wake_at = self.now() + seconds })
end

function Runner:stopping()
  return self.stop == true
end

function Runner:finish(result)
  self.finished[#self.finished + 1] = { name = self.name, result = result }
  self.co, self.name, self.waiting, self.wake_at, self.stop = nil, nil, nil, nil, nil
end

function Runner:resume(...)
  local co = self.co
  local ok, request = coroutine.resume(co, ...)
  if not ok then
    self:finish({ ok = false, error = errors.new("SERVER_INTERNAL", tostring(request)),
                  traceback = debug.traceback(co) })
  elseif coroutine.status(co) == "dead" then
    self:finish(request or { ok = true })
  else
    self.waiting = request and request.wait
    self.wake_at = request and request.wake_at
  end
end

-- Starts fn(...) as the new task. Returns false if another task is running.
function Runner:start(name, fn, ...)
  if self.co then return false end
  self.link:abandon()
  local args = table.pack(...)
  self.co = coroutine.create(function() return fn(table.unpack(args, 1, args.n)) end)
  self.name = name
  self.stop = false
  self:resume()
  return true
end

-- Delivers a reply event from the link.
function Runner:on_reply(id, reply)
  if self.co and self.waiting == id then
    self.waiting = nil
    self:resume(reply)
  end
end

-- Wakes a sleeping task when its time has come.
function Runner:tick()
  if self.co and self.wake_at and self.now() >= self.wake_at then
    self.wake_at = nil
    self:resume()
  end
end

-- Returns and clears the finished tasks: list of { name, result }.
function Runner:take_finished()
  local finished = self.finished
  self.finished = {}
  return finished
end

return runner
