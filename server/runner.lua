-- Runs one task at a time (setup, a breeding run, ...) as a coroutine, so tasks can be
-- written step by step while the main loop keeps handling keyboard and network.
--
-- A task is a function(ctx) that returns a result table:
--   { ok = true/false, error = error object, lines = { text, ... }, stopped = true }
-- Inside a task, ctx.call / ctx.sleep / ctx.stopping come from this runner.
--
-- Pause and abort take effect at the next robot command or sleep of the task, never in
-- the middle of a robot command (a command the robot is carrying out always finishes).
-- An aborted task ends with { aborted = true }; the main program then tidies up.

local errors = require("server.errors")

local runner = {}

-- Raised inside the task to unwind it on abort.
local ABORT = setmetatable({}, { __tostring = function() return "aborted" end })

local Runner = {}
Runner.__index = Runner

-- link: server/link.lua object; now: clock function in seconds
function runner.new(link, now)
  return setmetatable({ link = link, now = now, co = nil, finished = {}, paused_total = 0 }, Runner)
end

function Runner:busy()
  return self.co ~= nil
end

function Runner:current()
  return self.name
end

-- "idle", "running", "paused" or "stopping"
function Runner:state()
  if not self.co then return "idle" end
  if self.aborting then return "stopping" end
  if self.paused then return "paused" end
  return "running"
end

-- Seconds that passed while not paused; use it to measure durations inside tasks.
function Runner:active_time()
  local paused_now = self.paused and (self.now() - self.pause_started) or 0
  return self.now() - self.paused_total - paused_now
end

-- Inside a task: wait here while paused, unwind when aborted.
function Runner:checkpoint()
  if self.aborting then error(ABORT, 0) end
  while self.paused do
    local value = coroutine.yield({ parked = true })
    if value == ABORT or self.aborting then error(ABORT, 0) end
  end
end

-- For tasks: send a robot command and wait for its reply.
function Runner:call(name, args)
  self:checkpoint()
  local id, err = self.link:call(name, args)
  if not id then return { ok = false, err = err, info = {} } end
  return coroutine.yield({ wait = id })
end

-- For tasks: wait without blocking the server.
function Runner:sleep(seconds)
  self:checkpoint()
  local value = coroutine.yield({ wake_at = self.now() + seconds })
  if value == ABORT then error(ABORT, 0) end
  self:checkpoint()
end

function Runner:stopping()
  return self.aborting == true
end

function Runner:finish(result)
  self.finished[#self.finished + 1] = { name = self.name, result = result }
  if self.paused then self.paused_total = self.paused_total + (self.now() - self.pause_started) end
  self.co, self.name, self.waiting, self.wake_at, self.parked = nil, nil, nil, nil, nil
  self.paused, self.aborting = nil, nil
end

function Runner:resume(...)
  local co = self.co
  local ok, request = coroutine.resume(co, ...)
  if not ok then
    if request == ABORT then
      self:finish({ ok = false, aborted = true, quiet = true })
    else
      self:finish({ ok = false, error = errors.new("SERVER_INTERNAL", tostring(request)),
                    traceback = debug.traceback(co) })
    end
  elseif coroutine.status(co) == "dead" then
    self:finish(request or { ok = true })
  else
    self.waiting = request and request.wait
    self.wake_at = request and request.wake_at
    self.parked = request and request.parked
  end
end

-- Starts fn(...) as the new task. Returns false if another task is running.
function Runner:start(name, fn, ...)
  if self.co then return false end
  self.link:abandon()
  local args = table.pack(...)
  self.co = coroutine.create(function() return fn(table.unpack(args, 1, args.n)) end)
  self.name = name
  self:resume()
  return true
end

-- Pauses the task at its next robot command or sleep.
function Runner:pause()
  if not self.co or self.paused or self.aborting then return false end
  self.paused = true
  self.pause_started = self.now()
  return true
end

-- Lets a paused task go on.
function Runner:unpause()
  if not self.co or not self.paused then return false end
  self.paused = false
  self.paused_total = self.paused_total + (self.now() - self.pause_started)
  if self.parked then
    self.parked = nil
    self:resume()
  end
  return true
end

-- Ends the task at its next robot command or sleep (at once if it is paused or sleeping).
function Runner:abort()
  if not self.co then return false end
  self.aborting = true
  self.paused = false
  if self.parked or self.wake_at then
    self.parked, self.wake_at = nil, nil
    self:resume(ABORT)
  end
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
