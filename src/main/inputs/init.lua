local socket = require 'socket'
local msgBus = require 'components.msg-bus'
local config = require 'config.config'
local userSettings = require 'config.user-settings'
local abs = math.abs
require 'main.inputs.keyboard-manager'

local state = {
  keyboard = require 'main.inputs.keyboard-manager'.state.keyboard,
  mouse = {
    position = {
      x = 0,
      y = 0,
    },
    lastPressed = {
      timeStamp = 0,
      x = 0,
      y = 0
    },
    drag = {
      started = false,
      isDragging = false,
      start = {
        x = 0,
        y = 0
      }
    },
    isDown = false,
  }
}

local function handleDragEvent()
  local isMouseDown = state.mouse.isDown
  local dragState = state.mouse.drag
  local isDragStart = isMouseDown and (not dragState.started)
  local isDragEnd = dragState.started and (not isMouseDown)

  if isMouseDown then
    local mx, my = love.mouse.getX(), love.mouse.getY()
    if isDragStart then
      dragState.started = true
      dragState.start.x = mx
      dragState.start.y = my
      msgBus.send(msgBus.MOUSE_DRAG_START, {
        startX = mx,
        startY = my,
        x = mx,
        y = my
      })
    end
    local dx, dy = mx - dragState.start.x, my - dragState.start.y
    local threshold = 2 -- minimum distance to consider it a drag
    local isDragging = (abs(dx) + abs(dy)) >= threshold
    dragState.isDragging = isDragging
    if isDragging then
      local event = {
        startX = dragState.start.x,
        startY = dragState.start.y,
        x = mx,
        y = my,
        dx = dx,
        dy = dy
      }
      msgBus.send(msgBus.MOUSE_DRAG, event)
    end
  end

  if isDragEnd then
    dragState.started = false
    dragState.isDragging = false
    local mx, my = love.mouse.getX(), love.mouse.getY()
    msgBus.send(msgBus.MOUSE_DRAG_END, {
      startX = dragState.start.x,
      startY = dragState.start.y,
      x = mx,
      y = my
    })
    return
  end
end

msgBus.on(msgBus.UPDATE, function()
  handleDragEvent()
end)

function love.mousepressed( x, y, button, istouch, presses )
  msgBus.send(
    msgBus.MOUSE_PRESSED,
    { x, y, button, istouch, presses }
  )
  if (not state.mouse.isDown) then
    local lastPressed = state.mouse.lastPressed
    lastPressed.timeStamp = socket.gettime()
    lastPressed.x, lastPressed.y = x, y
  end
  state.mouse.isDown = true
end

function love.mousereleased( x, y, button, istouch, presses )
  local message = { x, y, button, isTouch, presses }
  msgBus.send(
    msgBus.MOUSE_RELEASED,
    message
  )

  local timeBetweenRelease = socket.gettime() - state.mouse.lastPressed.timeStamp
  if timeBetweenRelease <= userSettings.mouseClickDelay then
    msgBus.send(msgBus.MOUSE_CLICKED, message)
  end

  state.mouse.isDown = false
end

function love.wheelmoved(x, y)
  msgBus.send(msgBus.MOUSE_WHEEL_MOVED, {x, y})
end

function love.textinput(t)
  msgBus.send(
    msgBus.GUI_TEXT_INPUT,
    t
  )
end

return {
  state = state
}