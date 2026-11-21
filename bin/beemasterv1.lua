-- Starts the beemasterv1 server. The installer copies this file to /home/bin, so the
-- command 'beemasterv1' works from anywhere.
local ROOT = "/home/beemasterv1"

-- OpenOS keeps loaded modules until reboot; drop ours so updates take effect.
for name in pairs(package.loaded) do
  if name:match("^server%.") or name:match("^shared%.") then package.loaded[name] = nil end
end
if not package.path:find(ROOT .. "/?.lua", 1, true) then
  package.path = ROOT .. "/?.lua;" .. package.path
end

return require("server.main").run(ROOT)
