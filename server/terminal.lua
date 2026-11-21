-- Screen output and keyboard input for the server terminal (OpenOS only).
-- The input line stays at the bottom; messages are printed above it, so typing is never
-- blocked by robot work and robot messages never mix into the typed text.

local terminal = {}

local Terminal = {}
Terminal.__index = Terminal

terminal.PROMPT = "> "
local KEY_ENTER, KEY_NUMPAD_ENTER, KEY_BACKSPACE = 28, 156, 14
local ALERT_COLOR = 0xFF0000

function terminal.new(term, computer)
  local gpu = term.gpu()
  return setmetatable({
    term = term, gpu = gpu, computer = computer, buffer = "", colors = gpu.getDepth() > 1,
  }, Terminal)
end

function Terminal:width()
  return (self.gpu.getResolution())
end

function Terminal:clear_line()
  local _, y = self.term.getCursor()
  self.gpu.fill(1, y, self:width(), 1, " ")
  self.term.setCursor(1, y)
end

function Terminal:redraw()
  self:clear_line()
  local visible = self.buffer
  local room = self:width() - #terminal.PROMPT - 1
  if #visible > room then visible = visible:sub(-room) end
  self.term.write(terminal.PROMPT .. visible)
end

-- Prints a line above the input line. color: 0xRRGGBB or nil.
function Terminal:print(text, color)
  self:clear_line()
  local old
  if color and self.colors then old = self.gpu.setForeground(color) end
  self.term.write(tostring(text) .. "\n")
  if old then self.gpu.setForeground(old) end
  self:redraw()
end

-- Red banner and three beeps. text starts with "DONE:" or "ERROR:".
function Terminal:alert(text)
  local bar = string.rep("=", math.min(50, self:width() - 1))
  self:print(bar, ALERT_COLOR)
  self:print(text, ALERT_COLOR)
  self:print(bar, ALERT_COLOR)
  for _ = 1, 3 do self.computer.beep(1000, 0.15) end
end

function Terminal:submit(line)
  self:clear_line()
  self.term.write(terminal.PROMPT .. line .. "\n")
  self.buffer = ""
  self:redraw()
  return line
end

-- Handles a key_down event. Returns the list of completed lines (zero or one).
function Terminal:key(char, code)
  if code == KEY_ENTER or code == KEY_NUMPAD_ENTER or char == 13 then
    return { self:submit(self.buffer) }
  end
  if code == KEY_BACKSPACE or char == 8 then
    if #self.buffer > 0 then
      self.buffer = self.buffer:sub(1, -2)
      self:redraw()
    end
  elseif char and char >= 32 and char < 127 then
    self.buffer = self.buffer .. string.char(char)
    self:redraw()
  end
  return {}
end

-- Handles a clipboard event; several pasted lines become several inputs.
function Terminal:paste(text)
  local lines = {}
  text = tostring(text):gsub("\r", "")
  local start = 1
  while true do
    local newline = text:find("\n", start, true)
    if not newline then
      self.buffer = self.buffer .. text:sub(start):gsub("[^\32-\126]", "")
      break
    end
    lines[#lines + 1] = self:submit(self.buffer .. text:sub(start, newline - 1))
    start = newline + 1
  end
  self:redraw()
  return lines
end

return terminal
