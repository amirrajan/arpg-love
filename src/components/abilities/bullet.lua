local Component = require 'modules.component'
local config = require 'config.config'
local groups = require 'components.groups'
local msgBus = require 'components.msg-bus'
local animationFactory = require 'components.animation-factory'
local collisionWorlds = require 'components.collision-worlds'
local collisionObject = require 'modules.collision'
local gameWorld = require 'components.game-world'
local Position = require 'utils.position'
local Color = require 'modules.color'
local memoize = require 'utils.memoize'
local typeCheck = require 'utils.type-check'
local random = math.random
local collisionGroups = require 'modules.collision-groups'
local drawOrders = require 'modules.draw-orders'

local oBlendMode = nil

local PreDraw = Component.create({
  init = function(self)
    Component.addToGroup(self, 'all')
  end,
  draw = function()
    oBlendMode = love.graphics.getBlendMode()
    love.graphics.setBlendMode('add')
  end,
  drawOrder = function()
    return drawOrders.BulletPreDraw
  end
})

local PostDraw = Component.create({
  init = function(self)
    Component.addToGroup(self, 'all')
  end,
  draw = function()
    if oBlendMode then
      love.graphics.setBlendMode(oBlendMode)
    end
  end,
  drawOrder = function()
    return drawOrders.BulletPostDraw
  end
})

local colMap = collisionWorlds.map
local EMPTY = {}

local defaultFilters = {
  obstacle = true,
}

local ColFilter = memoize(function(groupToMatch)
  return function (item, other)
    if collisionGroups.matches(other.group, groupToMatch) then
      return 'touch'
    end
    return false
  end
end)

local function drawBullet(self, scale, opacity)
  local ox, oy = self.animation:getOffset()
  love.graphics.setColor(Color.multiplyAlpha(self.color, opacity))
  love.graphics.draw(
      animationFactory.atlas
    , self.animation.sprite
    , self.x
    , self.y
    , self.angle
    , scale
    , scale
    , ox
    , oy
  )
end

local Bullet = {
  group = groups.all,

  -- [DEFAULTS]

  -- start position
  x = 0,
  y = 0,

  -- target position
  x2 = 0,
  y2 = 0,
  minDamage = 1,
  maxDamage = 2,
  startOffset = 0,
  scale = 1,
  lifeTime = 5,
  speed = 250,
  cooldown = 0.1,
  targetGroup = nil,
  color = {Color.rgba255(244, 220, 66, 1)},

  init = function(self)
    assert(
      self.targetGroup ~= nil,
      '[Bullet] `targetGroup` is required'
    )

    Component.addToGroup(self, 'autoVisibility')

    local dx, dy = Position.getDirection(self.x, self.y, self.x2, self.y2)
    self.direction = {x = dx, y = dy}
    self.x = self.x + self.startOffset * dx
    self.y = self.y + self.startOffset * dy

    self.animation = animationFactory:newStaticSprite('bullet/bullet-1')

    local w,h = select(3, self.animation.sprite:getViewport())
    local ox, oy = self.animation:getOffset()
    self.w = w
    self.h = h
    self.colObj = self:addCollisionObject(
      'projectile', self.x, self.y, w, h, ox, oy
    ):addToWorld(collisionWorlds.map)
  end,

  update = function(self, dt)
    self.lifeTime = self.lifeTime - dt

    local dx = self.direction.x * dt * self.speed
    local dy = self.direction.y * dt * self.speed
    self.x = self.x + dx
    self.y = self.y + dy
    self.animation:update(dt)
    local _, _, cols, len = self.colObj:move(self.x, self.y, ColFilter(self.targetGroup))
    local hasCollisions = len > 0
    local isExpired = self.lifeTime <= 0

    if hasCollisions or isExpired then
      local hitSuccess = false
      if hasCollisions then
        for i=1, len do
          local col = cols[i]
          local collisionParent = col.other.parent
          if collisionGroups.matches(col.other.group, self.targetGroup) then
            local isObstacleCollision = collisionGroups.matches(col.other.group, collisionGroups.obstacle)
            if (not isObstacleCollision) then
              local calcDamage = require 'modules.abilities.calc-damage'
              local msg = {
                parent = collisionParent,
                source = self:getId(),
                damage = calcDamage(self)
              }
              msgBus.send(msgBus.CHARACTER_HIT, msg)
            end
            hitSuccess = true

            local Spark = require 'components.abilities.spark'
            Spark.create({
              x = self.x,
              y = self.y,
              color = self.color
            })
          end
        end
      end

      if isExpired or hitSuccess then
        self:delete()
      end
    end

    self.angle = self.angle + (dt * 8)
  end,

  draw = function(self)
    if (not self.isInViewOfPlayer) then
      return
    end

    Component.get('lightWorld')
      :addLight(self.x, self.y, 10, self.color)

    local ox, oy = self.animation:getOffset()
    local scale = self.scale

    -- shadow
    love.graphics.setColor(0,0,0,0.15)
    love.graphics.draw(
      animationFactory.atlas
      , self.animation.sprite
      , self.x
      , self.y + self.h
      , self.angle
      , scale
      , scale / 2
      , ox
      , oy
    )

    -- draw in several passes to give it a brighter blur effect
    drawBullet(self, 1, 1)
    -- drawBullet(self, 1.4, 0.5)
    drawBullet(self, 2, 0.2)

    if config.collisionDebug then
      local debug = require 'modules.debug'
      local co = self.colObj
      debug.boundingBox('fill', co.x - co.ox, co.y - co.oy, co.w, co.h, false)
    end
  end,

  final = function(self)
    self.colObj:delete()
  end
}

Bullet.drawOrder = function(self)
  return drawOrders.BulletDraw
end

return Component.createFactory(Bullet)