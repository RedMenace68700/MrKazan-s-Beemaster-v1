-- Every error the program reports has its own code.
-- Messages look like:  [CODE] text

local errors = {}

errors.CODES = {
  -- terminal input
  INPUT_FORMAT = "Cannot read '%s' (expected: A + B = C or = C X)",
  INPUT_UNKNOWN_SPECIES = "Unknown species '%s' (not listed in species.txt)",
  INPUT_TARGET_IS_PARENT = "Target '%s' cannot also be a parent",
  INPUT_UNKNOWN_COMMAND = "Unknown command '%s' (type 'help')",
  INPUT_USAGE = "Usage: %s",
  INPUT_COUNT = "The number of cycles must be between 1 and %s",
  SETTING_UNKNOWN = "Unknown setting '%s' (type 'settings')",
  SETTING_BAD_VALUE = "Invalid value '%s' for %s (allowed: %s)",
  QUEUE_BUSY = "Cannot %s while the robot is busy",
  NOT_AVAILABLE = "'%s' is not available yet",

  -- setup
  SETUP_NO_LAYOUT = "No layout found, run 'setup' first",
  SETUP_MISSING = "Required component missing: %s",

  -- planning and breeding
  MISSING_PRINCESS = "No usable pure %s princess",
  MISSING_DRONE = "No usable pure %s drone",
  DRONE_SAFETY = "DroneSafetyMode protects the last pure %s drone",
  QUEST_LAST_PRINCESS = "QuestMode prohibits using up the last %s princess",
  BASIC_PRINCESS_MISSING = "No princess made only of basic bees (%s)",
  MAX_CYCLES = "Target not reached after %s cycles",
  CYCLE_TIMEOUT = "No princess in the output chest after %s s",
  HONEY_LOW = "Only %s honey drops left (MinHoney is %s)",
  NO_HONEY = "Analysis failed: no honey in the robot",
  OUTPUT_FULL = "Output chest has only %s free slots (MinFreeOutputSlots is %s)",
  SUPPLY_FULL = "All supply chests are full",
  PROVIDER_FULL = "All provider chests are full",
  INVENTORY_MISSING = "No inventory yet, run 'inventorysetup'",
  APIARY_BUSY = "The apiary is still working (%s inside)",
  NOT_A_BEE = "Slot %s of %s holds no %s",

  -- server
  SERVER_ALREADY_RUNNING = "beemasterv1 is already running on this computer",
  SERVER_NO_MODEM = "No wireless network card found",
  SERVER_INTERNAL = "Server error: %s",

  -- robot and network
  ROBOT_NOT_CONNECTED = "No robot connected (start or reboot the robot)",
  ROBOT_TIMEOUT = "Robot did not answer command #%s (%s)",
  ROBOT_VERSION = "Robot runs version %s, server expects %s",
  ROBOT_RESTARTED = "Robot restarted during command #%s (%s)",
  ROBOT_STALE_ID = "Robot already ran command #%s",
  ROBOT_COMPONENT_MISSING = "Robot is missing: %s",
  ROBOT_LOST = "Robot is at %s, expected %s",
  ROBOT_TRANSFER_FAILED = "Moving items failed (%s)",
  ROBOT_UNKNOWN_COMMAND = "Robot does not know command '%s'",
  ROBOT_BAD_ARGS = "Invalid arguments for robot command '%s'",
  ROBOT_BLOCKED = "Robot cannot move (%s)",
  ROBOT_NO_INVENTORY = "No inventory in front of the robot at %s",
  ROBOT_EMPTY_SLOT = "Slot %s is empty",
  ROBOT_SLOT_BUSY = "Slot %s is already occupied",
  ROBOT_MISMATCH = "Slot %s holds %s, expected %s",
  ROBOT_CHEST_FULL = "Chest %s is full",
  ROBOT_FULL = "The robot's inventory is full",
  ROBOT_INTERNAL = "Robot error in '%s': %s",
  PROTO_BAD_MESSAGE = "Unreadable message from %s",
}

-- Formats "[CODE] text". Missing or extra arguments never raise an error.
function errors.format(code, ...)
  local template = errors.CODES[code]
  if not template then return "[" .. tostring(code) .. "]" end
  local args = table.pack(...)
  for i = 1, args.n do args[i] = tostring(args[i]) end
  local ok, text = pcall(string.format, template, table.unpack(args, 1, args.n))
  if not ok then text = template end
  return "[" .. code .. "] " .. text
end

-- Error object passed around inside the server: { code = ..., msg = ... }
function errors.new(code, ...)
  return { code = code, msg = errors.format(code, ...) }
end

return errors
