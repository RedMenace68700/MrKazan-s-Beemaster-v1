-- Technical configuration (not player settings, see server/settings.lua).
-- Stored on the server next to the layout written by 'setup'.

local protocol = require("shared.protocol")

local config = {}

config.DEFAULTS = {
  port = protocol.DEFAULT_PORT,      -- wireless port shared with the robot
  honey_slot = 48,                   -- robot slot that always holds honey drops
  robot_timeout = 5,                 -- seconds to wait for a reply before sending again
  robot_retries = 6,                 -- resends before the robot counts as lost
  output_check_interval = 5,         -- seconds between output chest checks during a cycle
  chunk_size = protocol.CHUNK_SIZE,  -- bytes per network packet
}

-- saved: table loaded from the config file, or nil. Unknown keys are dropped and values
-- of the wrong type fall back to the default.
function config.new(saved)
  local result = {}
  for key, default in pairs(config.DEFAULTS) do
    local value = saved and saved[key]
    if type(value) == type(default) then
      result[key] = value
    else
      result[key] = default
    end
  end
  return result
end

return config
