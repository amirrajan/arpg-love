local Component = require 'modules.component'
local objectUtils = require 'utils.object-utils'
local groups = require 'components.groups'
local mapBlueprint = require 'components.map.map-blueprint'
local config = require 'config.config'
local memoize = require 'utils.memoize'
local Grid = require 'utils.grid'

local COLOR_TILE_OUT_OF_VIEW = {1,1,1,0.3}
local COLOR_TILE_IN_VIEW = {1,1,1,1}
local COLOR_WALL = {1,1,1,0.7}
local COLOR_GROUND = {0,0,0,0.2}
local floor = math.floor
local minimapTileRenderers = {
  -- obstacle
  [0] = function(self, x, y, originX, originY, isInViewport)
    love.graphics.setColor(COLOR_WALL)
    local rectSize = 1
    local x = (self.x * rectSize) + x
    local y = (self.y * rectSize) + y
    love.graphics.rectangle(
      'fill',
      x, y, rectSize, rectSize
    )
  end,
  -- walkable
  [1] = function(self, x, y, originX, originY, isInViewport)
    love.graphics.setColor(COLOR_GROUND)
    local rectSize = 1
    local x = (self.x * rectSize) + x
    local y = (self.y * rectSize) + y
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
  local Grid = require 'utils.grid'
  Grid.forEach(self.blocks, function(renderFn, x, y)
    love.graphics.push()
    love.graphics.translate(self.x + x, self.y + y)
    renderFn()
    love.graphics.pop()
  end)
  self.blocks = {}
end

-- minimap
local blueprint = objectUtils.assign({}, mapBlueprint, {
  id = 'miniMap',
  group = groups.hud,
  x = 50,
  y = 50,
  w = 100,
  h = 100,

  init = function(self)
    self.canvas = love.graphics.newCanvas()
    self.renderCache = {}
    self.stencil = function()
      love.graphics.rectangle(
        'fill',
        self.x,
        self.y,
        self.w,
        self.h
      )
    end
    self.blocks = {}
  end,

  renderStart = function(self)
    love.graphics.push()
    love.graphics.origin()
    love.graphics.setCanvas(self.canvas)
  end,

  render = function(self, value, _x, _y, originX, originY, isInViewport)
    local tileRenderer = minimapTileRenderers[value]
    if tileRenderer then
      local index = Grid.getIndexByCoordinate(#self.grid[1], _x, _y)
      if self.renderCache[index] then
        return
      end
      tileRenderer(self, _x, _y, originX, originY, isInViewport)
      self.renderCache[index] = true
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
    love.graphics.translate(tx, ty)
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
function blueprint.renderBlock(self, gridX, gridY, renderFn)
  local Grid = require 'utils.grid'
  Grid.set(self.blocks, gridX, gridY, renderFn)
end

return Component.createFactory(blueprint)