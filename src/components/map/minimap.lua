local Component = require 'modules.component'
local objectUtils = require 'utils.object-utils'
local groups = require 'components.groups'
local mapBlueprint = require 'components.map.map-blueprint'
local config = require 'config.config'
local memoize = require 'utils.memoize'
local Grid = require 'utils.grid'
local Dungeon = require 'modules.dungeon'

local COLOR_TILE_OUT_OF_VIEW = {1,1,1,0.3}
local COLOR_TILE_IN_VIEW = {1,1,1,1}
local COLOR_WALL = {1,1,1,0.8}
local COLOR_GROUND = {1,1,1,0.4}
local floor = math.floor
local minimapTileRenderers = {
  unwalkable = function(self, x, y)
    love.graphics.setColor(COLOR_WALL)
    local rectSize = 1
    local x = x
    local y = y
    love.graphics.rectangle(
      'fill',
      x, y, rectSize, rectSize
    )
  end,
  walkable = function(self, x, y)
    love.graphics.setColor(COLOR_GROUND)
    local rectSize = 1
    local x = x
    local y = y
    love.graphics.rectangle(
      'fill',
      x, y, rectSize, rectSize
    )
  end,
}

local function drawPlayerPosition(self, centerX, centerY)
  local playerDrawX, playerDrawY = self.x + centerX, self.y + centerY
  -- translucent background around player for better visibility
  love.graphics.setColor(1,1,1,0.3)
  local bgRadius = 5
  love.graphics.circle('fill', playerDrawX, playerDrawY, bgRadius)

  -- granular player position indicator
  love.graphics.setColor(1,1,0)
  love.graphics.circle('fill', playerDrawX, playerDrawY, 1)
end

local function drawDynamicBlocks(self)
  love.graphics.setCanvas(self.dynamicBlocksCanvas)
  love.graphics.clear()
  local oBlendMode = love.graphics.getBlendMode()
  love.graphics.setBlendMode('alpha', 'premultiplied')

  love.graphics.push()

    for coordIndex, renderFn in pairs(self.blocks) do
      local x, y = Grid.getCoordinateByIndex(self.grid, coordIndex)
      love.graphics.origin()
      love.graphics.translate(x, y)
      love.graphics.scale(1)
      renderFn()
    end

    for _,c in pairs(Component.groups.questObjects.getAll()) do
      local x,y = c.x/config.gridSize,
        c.y/config.gridSize
      love.graphics.origin()
      love.graphics.translate(x, y)
      love.graphics.scale(1)

      local AnimationFactory = require 'components.animation-factory'
      local Color = require 'modules.color'
      local questGraphic = AnimationFactory:newStaticSprite('gui-quest-point')
      love.graphics.setColor(Color.PALE_YELLOW)
      questGraphic:draw(0, 0)
    end

  love.graphics.pop()

  self.blocks = {}

  love.graphics.setCanvas()
  love.graphics.push()
  love.graphics.setBlendMode(oBlendMode)
  love.graphics.setColor(1,1,1)
  love.graphics.draw(self.dynamicBlocksCanvas)
  love.graphics.pop()
end

-- minimap
local MiniMap = objectUtils.assign({}, mapBlueprint, {
  id = 'miniMap',
  class = 'miniMap',
  group = groups.hud,
  x = 50,
  y = 50,
  w = 100,
  h = 100,

  isEmptyTile = Dungeon.isEmptyTile,

  getRectangle = function(self)
    return self.x, self.y, self.w, self.h
  end,

  init = function(self)
    Component.addToGroup(self, 'mapStateSerializers')

    -- 1-d array of visited indices
    self.visitedIndices = self.visitedIndices or {}

    self.canvas = love.graphics.newCanvas(4096, 4096)
    self.dynamicBlocksCanvas = love.graphics.newCanvas(4096, 4096)
    self.cleanup = function()
      self.canvas:release()
      self.dynamicBlocksCanvas:release()
    end

    local x,y,w,h = self:getRectangle()
    self.stencil = function()
      love.graphics.rectangle(
        'fill', x, y, w, h
      )
    end
    self.blocks = {}

    -- pre-draw indices that have already been visited
    self:renderStart()
    for index in pairs(self.visitedIndices) do
      local x, y = Grid.getCoordinateByIndex(self.grid, index)
      local value = Grid.get(self.grid, x, y)
      local tileRenderer = value and minimapTileRenderers[value.walkable and 'walkable' or 'unwalkable']
      if tileRenderer then
        tileRenderer(self, x, y)
      end
    end
    self:renderEnd()
  end,

  renderStart = function(self)
    local x,y,w,h = self:getRectangle()
    -- backround
    love.graphics.setColor(0,0,0,0.2)
    love.graphics.rectangle('fill', x, y, w, h)
    -- border
    love.graphics.setLineWidth(0.5)
    love.graphics.setColor(1,1,1,0.5)
    love.graphics.rectangle('line', x, y, w, h)

    love.graphics.push()
    love.graphics.origin()
    love.graphics.setCanvas(self.canvas)

    --[[
      NOTE: disabled for now since there is an issue upon start of game
      where the minimap at the player's start position does not render immediately
    ]]
    -- self:setRenderDisabled(self.isVisitedGridPosition)
  end,

  render = function(self, value, gridX, gridY)
    local tileRenderer = value and minimapTileRenderers[value.walkable and 'walkable' or 'unwalkable']
    if tileRenderer then
      local index = Grid.getIndexByCoordinate(self.grid, gridX, gridY)
      if self.visitedIndices[index] then
        return
      end
      tileRenderer(self, gridX, gridY)
      self.visitedIndices[index] = true
    end
  end,

  renderEnd = function(self)
    local centerX, centerY = self.w/2, self.h/2

    love.graphics.setCanvas()
    love.graphics.scale(self.scale)
    love.graphics.setBlendMode('alpha', 'premultiplied')
    love.graphics.stencil(self.stencil, 'replace', 1)
    love.graphics.setStencilTest('greater', 0)

    -- translate the minimap so its centered around the player
    local cameraX, cameraY  = self.camera:getPosition()
    local Position = require 'utils.position'
    local tx, ty = centerX - cameraX/self.gridSize, centerY - cameraY/self.gridSize
    love.graphics.translate(self.x + tx, self.y + ty)
    love.graphics.setColor(1,1,1,1)
    love.graphics.setBlendMode('alpha')
    love.graphics.draw(self.canvas)
    drawDynamicBlocks(self, centerX, centerY)
    love.graphics.setStencilTest()
    love.graphics.pop()

    drawPlayerPosition(self, centerX, centerY)
  end
})

-- adds a block for the next draw frame, and gets removed automatically each frame
function MiniMap.renderBlock(self, gridX, gridY, renderFn)
  local bounds = self.bounds
  if bounds then
    local thresholdX, thresholdY = 20, 40
    local isOutOfBounds = gridX < bounds.w - thresholdX or
      gridX > bounds.e + thresholdX or
      gridY < bounds.n - thresholdY or
      gridY > bounds.s + thresholdY
    if isOutOfBounds then
      return
    end
  end
  local Grid = require 'utils.grid'
  local index = Grid.getIndexByCoordinate(self.grid, gridX, gridY)
  self.blocks[index] = renderFn
end

function MiniMap.serialize(self)
  return objectUtils.immutableApply(self.initialProps, {
    visitedIndices = self.visitedIndices
  })
end

function MiniMap.final(self)
  self:cleanup()
end

return Component.createFactory(MiniMap)