-- 'go': works through the queue, one request after the other.
--
-- A request that is done, skipped (bees missing, OnMissing = skip) or failed leaves the
-- queue. With OnMissing = halt, and for problems with the robot, chests or honey, the
-- run stops and the request stays at the front of the queue. After every request the
-- robot stores whatever it still carries. At the end it goes home and the alert says
-- what happened.

local errors = require("server.errors")
local motion = require("server.motion")
local queue = require("server.queue")
local breeding = require("server.tasks.breeding")
local request = require("server.tasks.request")

local run = {}

local function summary(stats)
  local text = string.format("%d/%d requests done", stats.done, stats.total)
  if #stats.skipped > 0 then text = text .. ", skipped: " .. table.concat(stats.skipped, "; ") end
  if #stats.failed > 0 then text = text .. ", failed: " .. table.concat(stats.failed, "; ") end
  return text
end

-- Stores what the robot carries and drives home (best effort, errors are logged).
local function tidy(ctx)
  local ok, err = breeding.stash(ctx)
  if not ok then ctx.log:error(err.msg) end
  ok, err = motion.home(ctx)
  if not ok then ctx.log:error(err.msg) end
  ctx.save("inventory")
end

function run.run(ctx)
  local lay = ctx.state.layout
  if not (lay and lay.complete) then return { ok = false, error = errors.new("SETUP_NO_LAYOUT") } end
  if next(ctx.state.ledger.chests) == nil then return { ok = false, error = errors.new("INVENTORY_MISSING") } end
  if ctx.queue:size() == 0 then return { ok = true, quiet = true, lines = { "Queue is empty" } } end

  local ok, err = breeding.read_robot(ctx)
  if not ok then return { ok = false, error = err } end
  ok, err = breeding.stash(ctx)
  if not ok then return { ok = false, error = err } end

  local stats = { done = 0, total = 0, skipped = {}, failed = {} }
  while true do
    local entry = ctx.queue:peek()
    if not entry then break end
    local name = queue.describe(entry)
    ctx.log:info(string.format("Request #%d: %s", entry.id, name))
    local outcome = request.run(ctx, entry)
    local status = outcome.status

    if status == "stopped" then
      tidy(ctx)
      return { ok = true, stopped = true, alert = "DONE: stopped, " .. summary(stats) }
    end
    if (status == "missing" or status == "failed") and ctx.settings:get("OnMissing") == "halt" then
      status = "halt"
    end
    if status == "halt" then
      tidy(ctx)
      return { ok = false, error = outcome.error, alert = "ERROR: " .. outcome.error.msg .. " (" .. name .. ")" }
    end

    stats.total = stats.total + 1
    if status == "done" then
      stats.done = stats.done + 1
      ctx.log:info(string.format("Request #%d done after %d cycle(s)", entry.id, outcome.cycles))
    else
      local list = status == "missing" and stats.skipped or stats.failed
      list[#list + 1] = name
      ctx.log:warn(string.format("Request #%d %s: %s", entry.id, status == "missing" and "skipped" or "failed",
        outcome.error.msg))
    end
    ctx.queue:pop()
    ctx.save("queue")
    ok, err = breeding.stash(ctx)
    if not ok then
      tidy(ctx)
      return { ok = false, error = err, alert = "ERROR: " .. err.msg }
    end
    ctx.save("inventory")
  end

  tidy(ctx)
  return { ok = true, alert = "DONE: " .. summary(stats) }
end

return run
