-- beemasterv1 server, main program for OpenOS. Started by bin/beemasterv1.lua.
--
-- One loop handles keyboard, network and timers, so typing never blocks the robot and
-- the robot never blocks typing. Robot work runs as a task in server/runner.lua.
-- Everything the server must not forget lives in <root>/data.

local protocol = require("shared.protocol")
local grid = require("shared.grid")
local errors = require("server.errors")
local species = require("server.species")
local settings_module = require("server.settings")
local queue_module = require("server.queue")
local ledger_module = require("server.ledger")
local persist = require("server.persist")
local log_module = require("server.log")
local config_module = require("server.config")
local console = require("server.console")
local link_module = require("server.link")
local runner_module = require("server.runner")
local bundle = require("server.bundle")
local motion = require("server.motion")
local terminal = require("server.terminal")
local setup_task = require("server.tasks.setup")
local cycle_task = require("server.tasks.cycle")
local run_task = require("server.tasks.run")
local scanall_task = require("server.tasks.scanall")
local diag = require("server.tasks.diag")
local breeding = require("server.tasks.breeding")

local main = {}

local MAX_LOG_BYTES = 256 * 1024
local RED, YELLOW = 0xFF4040, 0xFFFF40

-- root: install directory; data: directory for saved state (default <root>/data)
function main.run(root, data)
  local component = require("component")
  local computer = require("computer")
  local event = require("event")
  local filesystem = require("filesystem")
  local term = require("term")

  -- only one instance per computer: a running one answers the ping
  event.push("beemasterv1_ping")
  if event.pull(1, "beemasterv1_pong") then
    io.stderr:write(errors.format("SERVER_ALREADY_RUNNING") .. "\n")
    return 1
  end

  local modem
  for address in component.list("modem") do
    local proxy = component.proxy(address)
    if proxy.isWireless() then
      modem = proxy
      break
    end
  end
  if not modem then
    io.stderr:write(errors.format("SERVER_NO_MODEM") .. "\n")
    return 1
  end

  local registry, species_err = species.load(root .. "/server/species.txt")
  if not registry then
    io.stderr:write("Cannot read species.txt: " .. tostring(species_err) .. "\n")
    return 1
  end
  -- basic species for "upgrade": server/basic.txt, same format as species.txt
  local basic = {}
  local basic_list = species.load(root .. "/server/basic.txt")
    or species.from_list({ "forest", "meadows", "modest", "common" })
  for _, name in ipairs(basic_list.names) do basic[name:lower()] = true end

  data = data or (root .. "/data")
  filesystem.makeDirectory(data)
  local function path(name) return data .. "/" .. name end

  local log_path = path("log.txt")
  if filesystem.exists(log_path) and filesystem.size(log_path) > MAX_LOG_BYTES then
    filesystem.remove(log_path .. ".old")
    filesystem.rename(log_path, log_path .. ".old")
  end

  local cfg = config_module.new(persist.load(path("config.dat")))
  local settings = settings_module.new(persist.load(path("settings.dat")))

  -- os.time/os.date run on game time. The real time comes from the modification time
  -- of a freshly written file, then advances with computer.uptime (real seconds).
  local function real_clock()
    local stamp = path(".clock")
    local file = io.open(stamp, "w")
    if not file then return nil end
    file:write("x")
    file:close()
    local modified = filesystem.lastModified(stamp)
    filesystem.remove(stamp)
    if type(modified) ~= "number" or modified <= 0 then return nil end
    if modified > 1e11 then modified = modified / 1000 end -- milliseconds
    local start_real, start_uptime = modified, computer.uptime()
    return function()
      local t = math.floor(start_real + computer.uptime() - start_uptime + settings:get("TimeZone") * 3600) % 86400
      return string.format("%02d:%02d:%02d", math.floor(t / 3600), math.floor(t / 60) % 60, t % 60)
    end
  end

  local ui = terminal.new(term, computer)
  local LEVEL_COLORS = { WARN = YELLOW, ERROR = RED }
  local log = log_module.new({
    path = log_path,
    clock = real_clock(),
    echo = function(line, level) ui:print(line, LEVEL_COLORS[level]) end,
  })
  local queue = queue_module.new(persist.load(path("queue.dat")))
  local saved_layout = persist.load(path("layout.dat"))
  local state = {
    layout = saved_layout,
    home = saved_layout and saved_layout.home,
    ledger = ledger_module.new(persist.load(path("inventory.dat"))),
    pos = nil,
  }

  local function save(what)
    local ok, err
    if what == "settings" then
      ok, err = persist.save(path("settings.dat"), settings:to_table())
    elseif what == "queue" then
      ok, err = persist.save(path("queue.dat"), queue:to_table())
    elseif what == "layout" then
      ok, err = persist.save(path("layout.dat"), state.layout)
    elseif what == "inventory" then
      ok, err = persist.save(path("inventory.dat"), state.ledger:to_table())
    end
    if not ok then log:error("Cannot save " .. tostring(what) .. ": " .. tostring(err)) end
  end

  local code_text, code_err = bundle.build(root)
  local port = cfg.port
  modem.open(port)
  local link = link_module.new({
    send = function(address, ...) modem.send(address, port, ...) end,
    broadcast = function(...) modem.broadcast(port, ...) end,
    now = computer.uptime,
    code = function() return code_text, code_err end,
    timeout = cfg.robot_timeout,
    retries = cfg.robot_retries,
    chunk_size = cfg.chunk_size,
  })
  local runner = runner_module.new(link, computer.uptime)

  local ctx = {
    call = function(name, args) return runner:call(name, args) end,
    sleep = function(seconds) return runner:sleep(seconds) end,
    stopping = function() return runner:stopping() end,
    log = log,
    state = state,
    settings = settings,
    config = cfg,
    basic = basic,
    queue = queue,
    save = save,
    clock = os.time,
    -- durations inside tasks leave out the time spent paused
    now = function() return runner:active_time() end,
  }
  local console_ctx = {
    species = registry, queue = queue, settings = settings,
    busy = function() return runner:busy() end,
  }

  local function start(name, fn, ...)
    if runner:busy() then
      ui:print(errors.format("QUEUE_BUSY", name), RED)
      return
    end
    if not link:connected() then
      ui:print(errors.format("ROBOT_NOT_CONNECTED"), RED)
      return
    end
    log:info("Starting " .. name)
    runner:start(name, fn, ...)
  end

  local function show_status()
    local robot_text = "not connected"
    if link:connected() then
      local rs = state.robot_status
      local energy = ""
      if rs and rs.max_energy and rs.max_energy > 0 then
        energy = string.format(", energy %d%%", math.floor(rs.energy / rs.max_energy * 100))
      end
      local carried = 0
      for _, item in pairs(state.carry or {}) do
        if item.kind then carried = carried + (item.size or 1) end
      end
      robot_text = string.format("connected (%s), %s%s, carrying %d bee(s)",
        link.robot:sub(1, 8), motion.describe(state.pos), energy, carried)
    end
    ui:print("Robot:     " .. robot_text)

    local task = runner:current()
    ui:print("Task:      " .. (task and (task .. " (" .. runner:state() .. ")") or "idle"))
    local p = state.progress
    if task and p then
      if p.request then
        ui:print(string.format("Request:   %s, cycle %d/%d: %s", p.request, p.cycle or 0, p.max or 0, p.note or ""))
      end
      if p.phase then
        ui:print(string.format("Step:      %s (%d s)", p.phase, math.floor(runner:active_time() - (p.since or 0))))
      end
    end

    local entries = queue:list()
    local names = {}
    for i = 1, math.min(3, #entries) do names[i] = "#" .. entries[i].id .. " " .. queue_module.describe(entries[i]) end
    if #entries > 3 then names[#names + 1] = "..." end
    ui:print(string.format("Queue:     %d request(s)%s", #entries, #names > 0 and (": " .. table.concat(names, "; ")) or ""))

    local held = state.carry and state.carry[breeding.honey_slot(ctx)]
    local in_robot = held and held.name == "Forestry:honeyDrop" and held.size or 0
    ui:print(string.format("Honey:     %d in the robot, %s in the honey chest", in_robot,
      state.honey_chest and tostring(state.honey_chest) or "?"))

    local chests = 0
    for _ in pairs(state.ledger.chests) do chests = chests + 1 end
    local layout_text = "none, run 'setup'"
    if state.layout then layout_text = state.layout.complete and "complete" or "incomplete, run 'setup'" end
    ui:print(string.format("Layout:    %s; inventory of %d chest(s)", layout_text, chests))
    if link:connected() and not runner:busy() then runner:start("status", diag.status, ctx) end
  end

  -- 'stop' while idle, or after an aborted task: empty the robot and send it home.
  local function tidy_up()
    if not link:connected() then
      ui:print(errors.format("ROBOT_NOT_CONNECTED"), RED)
      return
    end
    log:info("Storing what the robot carries and returning to the charger")
    runner:start("stop", diag.tidy, ctx)
  end

  local running = true

  -- "5/1", "3" -> { id = "5/1", slot = 3 } for a chest position, or nil
  local function chest_slot(id, slot_text)
    local position = grid.position(id)
    local slot = tonumber(slot_text)
    if not position or position.role == "apiary" or not slot or slot < 1 or slot ~= math.floor(slot) then
      return nil
    end
    return { id = id, slot = math.floor(slot) }
  end

  local function handle_line(line)
    local result = console.handle(console_ctx, line)
    for _, text in ipairs(result.lines) do ui:print(text, result.error and RED or nil) end
    if result.changed then save(result.changed) end
    local action = result.action
    if not action then return end
    if action == "quit" then
      if runner:busy() then
        ui:print(errors.format("QUEUE_BUSY", "quit"), RED)
      else
        running = false
      end
    elseif action == "stop" then
      if runner:current() == "stop" then
        ui:print("Already stopping")
      elseif runner:busy() then
        log:info("Stopping " .. runner:current() .. " after the robot's current command")
        runner:abort()
      else
        tidy_up()
      end
    elseif action == "pause" then
      if runner:state() == "running" then
        runner:pause()
        log:info("Pausing " .. runner:current() .. " before the robot's next command, 'go' continues")
      elseif runner:state() == "paused" then
        ui:print("Already paused, 'go' continues")
      else
        ui:print("The robot is idle")
      end
    elseif action == "status" then
      show_status()
    elseif action == "go" then
      if runner:state() == "paused" then
        runner:unpause()
        log:info("Continuing " .. runner:current())
      else
        start("go", run_task.run, ctx)
      end
    elseif action == "setup" then
      start("setup", setup_task.run, ctx, {})
    elseif action == "inventorysetup" then
      start("inventorysetup", setup_task.run, ctx, { scan = true })
    elseif action == "scanall" then
      start("scanall", scanall_task.run, ctx)
    elseif action == "cycle" then
      local princess = chest_slot(result.args[1], result.args[2])
      local drone = chest_slot(result.args[3], result.args[4])
      if not (princess and drone) then
        ui:print(errors.format("INPUT_USAGE", "cycle <position> <slot> <position> <slot>, e.g. cycle 2/1 1 2/1 2"), RED)
        return
      end
      start("cycle", cycle_task.run, ctx, princess, drone)
    elseif action == "dump" then
      local at = chest_slot(result.args[1], result.args[2])
      if not at then
        ui:print(errors.format("INPUT_USAGE", "dump <position> <slot>, e.g. dump 5/1 3"), RED)
        return
      end
      local id, slot = at.id, at.slot
      start("dump", diag.dump, ctx, id, slot, function(text)
        local file = io.open(path("dump.txt"), "a")
        if file then
          file:write(text)
          file:close()
        end
      end)
    else
      ui:print(errors.format("NOT_AVAILABLE", action), YELLOW)
    end
  end

  local function on_link_event(ev)
    if ev.type == "reply" then
      runner:on_reply(ev.id, ev.reply)
    elseif ev.type == "hello" then
      local nav = ev.info.nav
      state.pos = motion.from_world(state.home, nav)
        or { x = grid.HOME.x, y = grid.HOME.y, h = grid.HOME.h, facing = nav and grid.direction_of_side(nav.facing) }
      log:info(string.format("Robot connected (%s) at %s", ev.address:sub(1, 8), motion.describe(state.pos)))
    elseif ev.type == "version" then
      log:error(errors.format("ROBOT_VERSION", ev.version, protocol.VERSION))
    elseif ev.type == "boot" then
      log:info(string.format("Robot %s is booting, program sent (%d bytes)", ev.address:sub(1, 8), ev.size))
    elseif ev.type == "boot_failed" then
      log:error("Cannot build the robot program: " .. tostring(ev.error))
    elseif ev.type == "crash" then
      local message = errors.format("ROBOT_INTERNAL", "robot program", ev.text:match("[^\n]*"))
      log:error(message)
      log:detail(ev.text)
      ui:alert("ERROR: " .. message)
    end
  end

  local function report_finished()
    for _, done in ipairs(runner:take_finished()) do
      local result = done.result or {}
      state.progress = nil
      if result.aborted then tidy_up() end
      for _, line in ipairs(result.lines or {}) do log:info(line) end
      if result.traceback then log:detail(result.traceback) end
      if result.error and result.error.detail then log:detail(result.error.detail) end
      if result.error and result.alert then log:error(result.error.msg) end
      if result.alert then
        ui:alert(result.alert)
      elseif result.stopped then
        ui:alert("DONE: " .. done.name .. " stopped")
      elseif result.ok then
        if not result.quiet then ui:alert("DONE: " .. done.name) end
      else
        local message = result.error and result.error.msg or "unknown error"
        if result.quiet then
          log:error(message)
        else
          ui:alert("ERROR: " .. done.name .. ": " .. message)
        end
      end
    end
  end

  local function loop()
    while running do
      local signal = table.pack(event.pull(0.25))
      local name = signal[1]
      local lines
      if name == "key_down" then
        lines = ui:key(signal[3], signal[4])
      elseif name == "clipboard" then
        lines = ui:paste(signal[3])
      elseif name == "modem_message" and signal[4] == port then
        link:handle(signal[3], table.unpack(signal, 6, signal.n))
      elseif name == "beemasterv1_ping" then
        event.push("beemasterv1_pong")
      end
      for _, line in ipairs(lines or {}) do handle_line(line) end
      link:poll()
      for _, ev in ipairs(link:take_events()) do on_link_event(ev) end
      runner:tick()
      report_finished()
    end
  end

  ui:print("beemasterv1 " .. protocol.VERSION)
  for _, warning in ipairs(settings.warnings) do log:warn(warning) end
  if not code_text then log:error("Cannot build the robot program: " .. tostring(code_err)) end
  if not (state.layout and state.layout.complete) then log:warn(errors.format("SETUP_NO_LAYOUT")) end
  ui:print(console.PROMPT)
  link:discover()

  local ok, err = xpcall(loop, debug.traceback)
  modem.close(port)
  term.write("\n")
  if not ok and not tostring(err):find("interrupted", 1, true) then
    log:error(errors.format("SERVER_INTERNAL", tostring(err):match("[^\n]*")))
    log:detail(err)
    return 1
  end
  return 0
end

return main
