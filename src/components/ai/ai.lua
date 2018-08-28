local Component = require 'modules.component'
local groups = require 'components.groups'
local animationFactory = require 'components.animation-factory'
local msgBus = require 'components.msg-bus'
local PopupTextController = require 'components.popup-text'
local getAdjacentWalkablePosition = require 'modules.get-adjacent-open-position'
local collisionObject = require 'modules.collision'
local uid = require'utils.uid'
local tween = require 'modules.tween'
local socket = require 'socket'
local distOfLine = require'utils.math'.dist
local memoize = require'utils.memoize'
local LineOfSight = memoize(require'modules.line-of-sight')
local Perf = require'utils.perf'
local dynamic = require'modules.dynamic-module'
local Math = require 'utils.math'

local Ai = {
  group = groups.all,
  health = 10,
  pulseTime = 0,
  speed = 100,
  attackRange = 8,
  sightRadius = 11,
  isAggravated = false,
  gridSize = 1,
  animation = animationFactory:new({
    'pixel-white-1x1'
  }),
  COLOR_FILL = {0,0.9,0.3,1},
  drawOrder = function(self)
    return self.group.drawOrder(self) + 1
  end
}

local popupText = PopupTextController.create()

-- gets directions from grid position, adjusting vectors to handle wall collisions as needed
local aiPathWithAstar = require'modules.flow-field.pathing-with-astar'

Ai.debugLineOfSight = dynamic('components/ai/line-of-sight.debug.lua')

function Ai:checkLineOfSight(grid, WALKABLE, targetX, targetY, debug)
  if not targetX then
    return false
  end

  local gridX, gridY = self.pxToGridUnits(self.x, self.y, self.gridSize)
  local gridTargetX, gridTargetY = self.pxToGridUnits(targetX, targetY, self.gridSize)
  return LineOfSight(grid, WALKABLE, debug)(
    gridX, gridY, gridTargetX, gridTargetY
  )
end

function Ai:aggravatedRadius()
  local playerFlowFieldDistance = Component.get('PLAYER')
    :getProp('flowFieldDistance')
  return (playerFlowFieldDistance - 3) * self.gridSize
end

function Ai:autoUnstuckFromWallIfNeeded(grid, gridX, gridY)
  local row = grid[gridY]
  local isInsideWall = (not row) or (row[gridX] ~= self.WALKABLE)

  if isInsideWall then
    local openX, openY = getAdjacentWalkablePosition(grid, gridX, gridY, self.WALKABLE)
    if openX then
      local nextX, nextY = openX * self.gridSize, openY * self.gridSize
      self.x = nextX
      self.y = nextY
      self.collision:update(
        self.x,
        self.y,
        self.w,
        self.h
      )
    end
  end
end

local COLLISION_SLIDE = 'slide'
local collisionFilters = {
  player = true,
  ai = true,
  obstacle = true
}
local function collisionFilter(item, other)
  if collisionFilters[other.group] then
    return COLLISION_SLIDE
  end
  return false
end

local function hitAnimation()
  local frame = 0
  local animationLength = 4
  while frame < animationLength do
    frame = frame + 1
    coroutine.yield(false)
  end
  coroutine.yield(true)
end

local function handleHits(self)
  self.isAggravated = false
  local hitCount = #self.hits
  if hitCount > 0 then
    for i=1, hitCount do
      local hit = self.hits[i]
      self.health = self.health - hit.damage

      local offsetCenter = 6
      popupText:new(
        hit.damage,
        self.x + (self.w / 2) - offsetCenter,
        self.y - self.h
      )

      local isDestroyed = self.health <= 0
      if isDestroyed then
        msgBus.send(msgBus.ENEMY_DESTROYED, {
          x = self.x,
          y = self.y,
          experience = 1
        })
        self:delete()
        return
      end

      self.hits[i] = nil
    end

    self.hitAnimation = coroutine.wrap(hitAnimation)
    self.isAggravated = true
  end
end

local ability1 = (function()
  local curCooldown = 0
  local skill = {}

  function skill.use(self, targetX, targetY)
    if curCooldown > 0 then
      return skill
    else
      local Attack = require 'components.abilities.bullet'
      local projectile = Attack.create({
          debug = false
        , x = self.x
        , y = self.y
        , x2 = targetX
        , y2 = targetY
        , speed = 125
        , cooldown = 0.3
        , targetGroup = 'player'
      })
      curCooldown = projectile.cooldown
      return skill
    end
  end

  function skill.updateCooldown(dt)
    curCooldown = curCooldown - dt
    return skill
  end

  return skill
end)()

local abilityDash = (function()
  local curCooldown = 0
  local skill = {}

  function skill.use(self)
    if curCooldown > 0 then
      return skill
    else
      local Dash = require 'components.abilities.dash'
      local projectile = Dash.create({
          fromCaster = self
        , cooldown = 0.5
      })
      curCooldown = projectile.cooldown
      return skill
    end
  end

  function skill.updateCooldown(dt)
    curCooldown = curCooldown - dt
    return skill
  end

  return skill
end)()

function Ai._update2(self, grid, flowField, dt)
  local playerRef = Component.get('PLAYER')
  local playerX, playerY = playerRef:getPosition()
  local gridDistFromPlayer = Math.dist(self.x, self.y, playerX, playerY) / self.gridSize
  self.isInViewOfPlayer = gridDistFromPlayer <= 40

  if self.pulseTime >= 0.4 then
    self.pulseDirection = -1
  elseif self.pulseTime <= 0 then
    self.pulseDirection = 1
  end
  self.pulseTime = self.pulseTime + dt * self.pulseDirection

  handleHits(self)

  if self:isDeleted() then
    return
  end

  if self.hitAnimation then
    local done = self.hitAnimation()
    if done then
      self.hitAnimation = nil
    end
  end

  local centerOffset = self.padding
  local prevGridX, prevGridY = self.pxToGridUnits(self.prevX or 0, self.prevY or 0, self.gridSize)
  local gridX, gridY = self.pxToGridUnits(self.x, self.y, self.gridSize)
  -- we can use this detect whether the agent is stuck if the grid position has remained the same for several frames and was trying to move
  local isNewGridPosition = prevGridX ~= gridX or prevGridY ~= gridY
  local isNewFlowField = self.lastFlowField ~= flowField
  local actualSightRadius = self.isAggravated and
      self:aggravatedRadius() or
      self.sightRadius
  local targetX, targetY = self.findNearestTarget(
    self.x,
    self.y,
    actualSightRadius
  )
  local canSeeTarget = self:checkLineOfSight(grid, self.WALKABLE, targetX, targetY)
  local shouldGetNewPath = flowField and canSeeTarget
  local distFromTarget = canSeeTarget and distOfLine(self.x, self.y, targetX, targetY) or math.huge
  local isInAttackRange = canSeeTarget and (distFromTarget <= self.attackRange)

  self:autoUnstuckFromWallIfNeeded(grid, gridX, gridY)

  self.canSeeTarget = canSeeTarget

  if canSeeTarget then
    local Dash = require 'components.abilities.dash'
    if self.attackRange <= Dash.range then
      if (distFromTarget <= Dash.range) then
        abilityDash.use(self)
        abilityDash.updateCooldown(dt)
      end
    end

    if isInAttackRange then
      ability1.use(self, targetX, targetY)
      ability1.updateCooldown(dt)
      -- we're already in attack range, so we don't need to move
      return
    end
  end

  if shouldGetNewPath then
    self.pathComplete = false
    local distanceToPlanAhead = actualSightRadius / self.gridSize
    self.pathWithAstar = self.getPathWithAstar(flowField, grid, gridX, gridY, distanceToPlanAhead, self.WALKABLE, self.scale)

    local index = 1
    local path = self.pathWithAstar
    local pathLen = #path
    local posTween
    local done = true
    local isEmptyPath = pathLen == 0

    if isEmptyPath then
      return
    end

    self.positionTweener = function(dt)
      if index > pathLen then
        self.pathComplete = true
        return
      end

      if done then
        local pos = path[index]
        local nextPos = {
          x = pos.x * self.gridSize + centerOffset,
          y = pos.y * self.gridSize + centerOffset
        }
        local dist = distOfLine(self.x, self.y, nextPos.x, nextPos.y)

        if dist == 0 then
          print(self.x, self.y, nextPos.x, nextPos.y)
        end

          local duration = dist / self.speed

        local easing = tween.easing.linear
        posTween = tween.new(duration, self, nextPos, easing)
        index = index + 1
      end
      done = posTween:update(dt)
    end
  end

  if not self.positionTweener then
    return
  end

  local originalX, originalY = self.x, self.y
  self.positionTweener(dt)
  local nextX, nextY = self.x, self.y

  local isMoving = originalX ~= nextX or originalY ~= nextY
  if not isMoving then
    return
  end

  local actualX, actualY, cols, len = self.collision:move(nextX, nextY, collisionFilter)
  local hasCollisions = len > 0

  self.hasDeviatedPosition = hasCollisions and
    (originalX ~= actualX or originalY ~= actualY)

  self.prevX = self.x
  self.prevY = self.y
  self.x = actualX
  self.y = actualY
  self.lastFlowField = flowField
end

local function drawShadow(self, ox, oy)
  love.graphics.setColor(0,0,0,0.15)
  love.graphics.draw(
    animationFactory.atlas,
    self.animation.sprite,
    self.x + 1,
    self.y + 10,
    0,
    self.w - 2,
    self.h,
    ox,
    oy
  )
end

function Ai.draw(self)
  if (not self.isInViewOfPlayer) then
    return
  end

  local padding = 0
  local sizeIncreaseX, sizeIncreaseY = (self.w * self.pulseTime), (self.h * self.pulseTime)
  local drawWidth, drawHeight = self.w + sizeIncreaseX, self.h + sizeIncreaseY
  local ox, oy = 1 + self.pulseTime/2, 1 + self.pulseTime/2

  drawShadow(self, ox, oy)

  -- border
  local borderWidth = 2
  love.graphics.setColor(0,0,0)
  love.graphics.draw(
    animationFactory.atlas,
    self.animation.sprite,
    self.x,
    self.y,
    0,
    drawWidth,
    drawHeight,
    ox,
    oy
  )

  if self.hitAnimation then
    love.graphics.setColor(1,1,1,1)
  else
    love.graphics.setColor(self.COLOR_FILL)
  end
  love.graphics.draw(
    animationFactory.atlas,
    self.animation.sprite,
    self.x + borderWidth/2,
    self.y + borderWidth/2,
    0,
    drawWidth - borderWidth,
    drawHeight - borderWidth,
    ox,
    oy
  )

  -- self:debugLineOfSight()
end

function Ai.init(self)
  assert(self.WALKABLE ~= nil)
  assert(type(self.pxToGridUnits) == 'function')
  assert(self.collisionWorld ~= nil)
  assert(type(self.grid) == 'table')
  assert(type(self.gridSize) == 'number')
  local scale = self.scale
  local gridSize = self.gridSize
  self.hits = {}

  if scale % 1 == 0 then
    -- to prevent wall collision from getting stuck when pathing around corners, we'll adjust
    -- the agent size so its slightly smaller than the grid size.
    scale = scale - (2 / gridSize)
  end

  local scale = scale or 1
  local size = gridSize * scale
  --[[
    Padding is the difference between the full grid size and the actual rectangle size.
    Ie: if scale is 1.5, then the difference is (2 - 1.5) * gridSize
  ]]
  local padding = math.ceil(scale) * gridSize - size
  self.padding = padding

  local w, h = size, size
  self.w, self.h = w, h
  self.collision = self:addCollisionObject('ai', self.x, self.y, size, size)
    :addToWorld(self.collisionWorld)

  self.attackRange = self.attackRange * self.gridSize
  self.sightRadius = self.sightRadius * self.gridSize
  self.getPathWithAstar = Perf({
    enabled = false,
    done = function(t)
      consoleLog('ai path:', t)
    end
  })(aiPathWithAstar())

  msgBus.subscribe(function(msgType, msgValue)
    if self:isDeleted() then
      return msgBus.CLEANUP
    end

    if msgBus.CHARACTER_HIT == msgType and msgValue.parent == self then
      table.insert(self.hits, msgValue)
    end
  end)
end

return Component.createFactory(Ai)