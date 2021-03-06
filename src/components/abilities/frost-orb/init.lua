local Component = require 'modules.component'
local AnimationFactory = require 'components.animation-factory'
local CollisionWorlds = require 'components.collision-worlds'
local collisionGroups = require 'modules.collision-groups'
local Sound = require 'components.sound'
local Color = require 'modules.color'
local CloudParticle = require 'components.abilities.frost-orb.particle-effect'

local function obstacleFilter(item)
  return collisionGroups.matches(item.group, 'obstacle') and 'slide' or false
end

Component.create({
  id = 'FrostOrbHitCounter',
  group = 'all',
  update = function(self, dt)
    for id,target in pairs(Component.groups.frostOrbTargets.getAll()) do
      target.hitClock = target.hitClock + dt
      if (target.hitClock >= target.minTimeBetweenHits) then
        Component.removeFromGroup(id, 'frostOrbTargets')
      end
    end
  end
})

local Shard = Component.createFactory({
  minTimeBetweenHits = 0.1,
  init = function(self)
    Component.addToGroup(self, 'gameWorld')

    self.clock = 0

    local length = 1000000
    self.x2, self.y2 = self.x + length * math.sin(-self.angle),
        self.y + length * math.cos(-self.angle) - self.z
    local initialOffset = 5
    self.x, self.y = self.x + initialOffset * math.sin(-self.angle),
      self.y + initialOffset * math.cos(-self.angle) - self.z

    self.animation = AnimationFactory:newStaticSprite('frost-orb/frost-orb-shard')
    self.ox, self.oy = self.animation:getOffset()
    local Position = require 'utils.position'
    self.dx, self.dy = Position.getDirection(self.x, self.y, self.x2, self.y2)
    local sourceRef = Component.get(self.source)
    local directionMagnitude = 0.3
    self.dx, self.dy = self.dx + (sourceRef.dx * directionMagnitude),
      self.dy + (sourceRef.dy * directionMagnitude)
  end,
  update = function(self, dt)
    self.clock = self.clock + dt
    local isExpired = self.clock >= self.lifeTime
    if isExpired then
      return self:delete()
    end

    self.x = self.x + dt * self.dx * self.speed
    self.y = self.y + dt * self.dy * self.speed

    local items, len = self.collisionWorld:queryRect(self.x - self.ox, self.y - self.ox, 6, 6)
    if (len > 0) then
      for i=1, len do
        cItem = items[i]
        local collisionGroups = require 'modules.collision-groups'
        local isHit = collisionGroups.matches(
          cItem.group,
          self.target
        )
        local hitParent = cItem.parent
        local sourceId = self.source
        local recentlyHit = isHit and Component.groups.frostOrbTargets.getAll()[sourceId]
        if isHit and (not recentlyHit) then
          local msgBus = require 'components.msg-bus'
          Component.addToGroup(sourceId, 'frostOrbTargets', {
            hitClock = 0,
            minTimeBetweenHits = self.minTimeBetweenHits
          })
          msgBus.send(msgBus.CHARACTER_HIT, {
            parent = hitParent,
            source = sourceId,
            coldDamage = math.random(self.coldDamage.x, self.coldDamage.y),
          })
        end
        if collisionGroups.matches(cItem.group, 'obstacle') then
          self:delete(true)
        end
      end
    end
  end,
  draw = function(self)
    love.graphics.setColor(self.color or Color.WHITE)
    love.graphics.draw(
      AnimationFactory.atlas,
      self.animation.sprite,
      self.x,
      self.y,
      self.angle + math.pi/2,
      1, 1,
      self.ox, self.oy
    )
  end,
  drawOrder = function(self)
    return 4
  end,
})

local FrostOrb = Component.createFactory({
  group = 'all',
  x = 0,
  y = 0,
  startOffset = 10,
  collisionWorld = CollisionWorlds.map,
  lifeTime = 1,
  scale = 1,
  opacity = 1,
  angle = math.pi + math.pi/2,
  speed = 45,
  projectileRate = 5,
  projectileLifeTime = 0.8,
  minTimeBetweenHits = 0.12,
  projectileSpeed = 120,
  init = function(self)
    Component.addToGroup(self, 'gameWorld')
    self.cloudParticle = CloudParticle.create():setParent(self)

    local Position = require 'utils.position'
    self.dx, self.dy = Position.getDirection(self.x, self.y, self.x2, self.y2)

    self.clock = 0
    self.shardClock = 0
    self.rotation = math.random(0, 4) * 0.5

    self.x, self.y = self.x + (self.dx * self.startOffset),
      self.y + (self.dy * self.startOffset)
    self.animation = AnimationFactory:newStaticSprite('frost-orb/frost-orb-core')
    self.ox, self.oy = self.animation:getOffset()
    self.width, self.height = self.animation:getWidth(), self.animation:getHeight()

    self.sound = Sound.playEffect('frost-orb.wav')
  end,
  update = function(self, dt)
    self.rotation = self.rotation - dt * 20
    self.clock = self.clock + dt
    self.shardClock = self.shardClock + dt

    self.cloudParticle.x = self.x
    self.cloudParticle.y = self.y

    local isExpired = self.clock >= self.lifeTime
    if isExpired then
      self:onExpire()
    end

    if self.expiring then
      return
    end

    self.x, self.y = self.x + self.speed * dt * self.dx, self.y + self.speed * dt * self.dy
    local items, len = self.collisionWorld:queryRect(self.x - self.ox, self.y - self.oy, self.width, self.height, obstacleFilter)
    if (len > 0) then
      self:onExpire()
    end

    local shardRate = 0.125 / self.projectileRate
    if self.shardClock > shardRate then
      self.shardClock = 0
      local params = {
        x = self.x,
        y = self.y,
        angle = self.rotation,
        coldDamage = self.coldDamage,
        collisionWorld = self.collisionWorld,
        target = self.target,
        group = self.group,
        lifeTime = self.projectileLifeTime,
        minTimeBetweenHits = self.minTimeBetweenHits,
        speed = self.projectileSpeed,
        source = self:getId()
      }
      Shard.create(params)
    end
  end,
  draw = function(self, dt)
    love.graphics.setColor(0,0,0,math.min(0.3, self.opacity))
    -- shadow
    self.animation:draw(
      self.x,
      self.y + self.animation:getHeight(),
      self.angle,
      self.scale/2,
      self.scale,
      self.ox,
      self.oy
    )

    love.graphics.setColor(1,1,1,self.opacity)
    self.animation:draw(
      self.x,
      self.y,
      self.angle,
      self.scale,
      self.scale,
      self.ox,
      self.oy
    )
  end,
  drawOrder = function(self)
    return Component.groups.all:drawOrder(self) + 1
  end,
  onExpire = function(parent)
    parent.expiring = true
    parent.speed = 0
    parent.volume = 1
    local tween = require 'modules.tween'
    Component.create({
      init = function(self)
        Component.addToGroup(self, parent.group)
        self.tween = tween.new(0.25, parent, {
          opacity = 0,
          scale = 0,
          volume = 0
        }, tween.easing.outQuad)
      end,
      update = function(self, dt)
        local complete = self.tween:update(dt)
        Sound.modify(parent.sound, 'setVolume', parent.volume)
        if complete then
          parent:delete(true)
          local Sound = require 'components.sound'
          Sound.stopEffect(parent.sound)
        end
      end
    }):setParent(parent)
  end,
  final = function(self)
    Sound.stopEffect(self.sound)
  end
})

return FrostOrb