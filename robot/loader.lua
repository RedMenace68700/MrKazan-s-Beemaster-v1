-- beemasterv1 robot loader. Flash this file onto the robot's EEPROM (max 4096 bytes).
-- It asks the server for the robot program, loads it and runs it. If the program
-- crashes, the error is sent to the server and the robot reboots after 10 seconds.
local PORT, TAG = 200, "beemasterv1"
local c, cp = component, computer
local m = c.proxy(c.list("modem")())
m.open(PORT)
local parts, total, server = {}, nil, nil
local function ask()
  parts, total = {}, nil
  m.broadcast(PORT, TAG, "boot")
end
ask()
local deadline = cp.uptime() + 5
local code
while not code do
  local e, _, from, port, _, tag, kind, i, n, data = cp.pullSignal(1)
  if e == "modem_message" and port == PORT and tag == TAG and kind == "code" then
    if from ~= server then parts, server = {}, from end
    total, parts[i] = n, data
    local complete = true
    for k = 1, total do
      if not parts[k] then complete = false break end
    end
    if complete then code = table.concat(parts, "", 1, total) end
    deadline = cp.uptime() + 5
  elseif cp.uptime() > deadline then
    ask()
    deadline = cp.uptime() + 5
  end
end
local fn, err = load(code, "=beemasterv1", "t")
local ok = fn ~= nil
if ok then ok, err = xpcall(fn, debug and debug.traceback or tostring, m, server, PORT) end
m.send(server, PORT, TAG, "crash", tostring(err):sub(1, 4000))
local wait = cp.uptime() + 10
while cp.uptime() < wait do cp.pullSignal(wait - cp.uptime()) end
cp.shutdown(true)
