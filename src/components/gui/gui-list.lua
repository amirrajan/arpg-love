local Color = require 'modules.color'
local Component = require 'modules.component'
local Gui = require 'components.gui.gui'
local f = require 'utils.functional'

local function iterateChildrenRecursively(children, callback)
  for _,child in pairs(children) do
    iterateChildrenRecursively(
      Component.getChildren(child),
      callback
    )
    callback(child)
  end
end

local function scrollbars(self)
  local verticalRatio = self.h / (self.h + self.scrollHeight)
  local horizontalRatio = self.w / (self.w + self.scrollWidth)

  if self.scrollHeight > 0 then
    local scrollbarWidth = 5
    local scrollbarHeight = verticalRatio * self.h
    love.graphics.setColor(Color.PRIMARY)
    love.graphics.rectangle(
      'fill',
      self.x + self.w - scrollbarWidth,
      self.y - (self.scrollTop * verticalRatio),
      scrollbarWidth,
      scrollbarHeight
    )
  end

  if self.scrollWidth > 0 then
    local scrollbarWidth = horizontalRatio * self.w
    local scrollbarHeight = 5
    love.graphics.setColor(Color.PRIMARY)
    love.graphics.rectangle(
      'fill',
      self.x - (self.scrollLeft * horizontalRatio),
      self.y + self.h - scrollbarHeight,
      scrollbarWidth,
      scrollbarHeight
    )
  end
end

local GuiList = {
  childNodes = {},
  width = 1,
  height = 1,
  contentWidth = nil,
  contentHeight = nil,
  scrollTop = 0,
  scrollLeft = 0
}

function GuiList.init(self)
  local parent = self
  Component.addToGroup(self, 'gui')

  self.contentWidth = self.contentWidth or self.width
  self.contentHeight = self.contentHeight or self.height
  local children, width, height, contentWidth, contentHeight =
    self.childNodes, self.width, self.height, self.contentWidth, self.contentHeight

  local function guiStencil()
    love.graphics.rectangle(
      'fill',
      self.x,
      self.y,
      self.width,
      self.height
    )
  end

  local baseDrawOrder = self.drawOrder

  -- disable automatic drawing so we can manually draw it ourself
  local function disableDraw(child)
    child:setDrawDisabled(true)
  end
  iterateChildrenRecursively(children, disableDraw)

  local listNode = Gui.create({
    x = self.x,
    y = self.y,
    inputContext = self.inputContext,
    w = 1,
    h = 1,
    type = Gui.types.LIST,
    children = children,
    scrollHeight = 1,
    scrollWidth = 1,
    scrollSpeed = 8,
    onUpdate = function(self)
      self.children = parent.childNodes
      local width, height, contentWidth, contentHeight =
        parent.width, parent.height, parent.contentWidth, parent.contentHeight
      self.w = width
      self.h = height
      self.scrollHeight = (contentHeight >= height) and (contentHeight - height) or 0
      self.scrollWidth = (contentWidth >= width) and (contentWidth - width) or width
      parent.scrollTop = self.scrollTop
    end,
    onScroll = function(self)
    end,
    render = function(self)
      -- setup stencil
      love.graphics.push()
      love.graphics.stencil(guiStencil, 'replace', 1)
      love.graphics.setStencilTest('greater', 0)

      iterateChildrenRecursively(self.children, function(child)
        child:draw()
      end)
      scrollbars(self)

      -- remove stencil
      love.graphics.setStencilTest()
      love.graphics.pop()
    end,
    drawOrder = baseDrawOrder
  }):setParent(self)
end

local function removeChildren(self)
  for i=1, #self.childNodes do
    self.childNodes[i]:delete(true)
  end
end

function GuiList.final(self)
  removeChildren(self)
end

return Component.createFactory(GuiList)