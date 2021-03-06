local Component = require 'modules.component'
local groups = require 'components.groups'
local msgBus = require 'components.msg-bus'
local msgBus = require 'components.msg-bus'
local ParticleFx = require 'components.particle.particle'
local config = require 'config.config'
local userSettings = require 'config.user-settings'
local animationFactory = require 'components.animation-factory'
local collisionWorlds = require 'components.collision-worlds'
local collisionObject = require 'modules.collision'
local CollisionGroups = require 'modules.collision-groups'
local camera = require 'components.camera'
local Position = require 'utils.position'
local Map = require 'modules.map-generator.index'
local Color = require 'modules.color'
local memoize = require 'utils.memoize'
local Math = require 'utils.math'
local WeaponCore = require 'components.player.weapon-core'
local InventoryController = require 'components.item-inventory.controller'
local Inventory = require 'components.item-inventory.inventory'
local HealSource = require 'components.heal-source'
require'components.item-inventory.equipment-change-handler'
local MenuManager = require 'modules.menu-manager'
local InputContext = require 'modules.input-context'
local F = require 'utils.functional'
local Object = require 'utils.object-utils'
local EventLog = require 'modules.log-db.events-log'
local UniverseMap = require 'components.hud.universe-map.universe-map-2'
local globalState = require 'main.global-state'
local gsa = require 'main.global-state-actions'

local colMap = collisionWorlds.map

local startPos = {
  x = config.gridSize * 3,
  y = config.gridSize * 3,
}

local frameRate = 60
local DIRECTION_RIGHT = 1
local DIRECTION_LEFT = -1

local movementCollisionGroup = 'obstacle enemyAi'

local function collisionFilter(item, other)
  if not CollisionGroups.matches(other.group, movementCollisionGroup) then
    return false
  end
  return 'slide'
end

local function setupDefaultInventory(items)
  local itemSystem = require(require('alias').path.itemSystem)
  local rootState = require 'main.global-state'.gameState

  for i=1, #items.equipment do
    local itemType = items.equipment[i]
    local module = require(require('alias').path.itemDefs..'.'..itemType)
    rootState:equipmentSwap(itemSystem.create(module))
  end

  for i=1, #items.inventory do
    local itemType = items.inventory[i]
    local module = require(require('alias').path.itemDefs..'.'..itemType)
    rootState:addItemToInventory(itemSystem.create(module))
  end
end

local function connectInventory()
  local rootState = globalState.gameState
  local inventoryController = InventoryController(rootState)

  -- add default weapons
  if rootState:get().isNewGame then
    setupDefaultInventory(
      require 'components.player.starting-items'
    )
  end

  -- trigger equipment change for items that were previously equipped from loading the state
  msgBus.send(msgBus.EQUIPMENT_CHANGE)
end

local function connectAutoSave(parent)
  local tick = require 'utils.tick'
  local Db = require 'modules.database'
  local lastSavedState = nil
  if (not parent.autoSave) then
    return
  end

  local rootState = require 'main.global-state'.gameState
  local sessionStartTime = os.time()
  local initialPlayTime = rootState:get().playTime
  local function saveState()
    rootState:set('isNewGame', false)
    local state = rootState:get()
    local date = require 'utils.date'
    local sessionDuration = os.time() - sessionStartTime
    local totalPlayTime = initialPlayTime + sessionDuration
    rootState:set('playTime', totalPlayTime)
    Db.load('saved-states'):put(
      rootState:getId(), {
        data = state,
        metadata = {
          displayName = state.characterName,
          playTime = totalPlayTime,
          playerLevel = state.level
        }
      }
    ):next(nil, function(err)
      msgBus.send('LOG_ERROR', err)
    end)
    lastSavedTime = currentTime
    lastSavedState = state
  end
  local autoSaveTimer = tick.recur(saveState, 0.5)
  Component.create({
    init = function(self)
      Component.addToGroup(self, groups.system)
    end,
    final = function()
      autoSaveTimer:stop()
    end
  }):setParent(parent)
end

msgBus.on(msgBus.PLAYER_FULL_HEAL, function()
  msgBus.send(msgBus.PLAYER_HEAL_SOURCE_ADD, {
    amount = math.pow(10, 10),
    source = 'PLAYER_FULL_HEALTH',
    duration = 0,
    property = 'health',
    maxProperty = 'maxHealth'
  })

  msgBus.send(msgBus.PLAYER_HEAL_SOURCE_ADD, {
    amount = math.pow(10, 10),
    source = 'PLAYER_FULL_ENERGY',
    duration = 0,
    property = 'energy',
    maxProperty = 'maxEnergy'
  })
end)

local function updateHealthRegeneration(healthRegeneration)
  local healthRegenerationDuration = math.pow(10, 10)
  msgBus.send(msgBus.PLAYER_HEAL_SOURCE_ADD, {
    source = 'PLAYER_HEALTH_REGENERATION',
    amount = healthRegenerationDuration * healthRegeneration,
    duration = healthRegenerationDuration,
    property = 'health',
    maxProperty = 'maxHealth'
  })
end

local function updateEnergyRegeneration(energyRegeneration)
  local energyRegenerationDuration = math.pow(10, 10)
  msgBus.send(msgBus.PLAYER_HEAL_SOURCE_ADD, {
    source = 'PLAYER_ENERGY_REGENERATION',
    amount = energyRegenerationDuration * energyRegeneration,
    duration = energyRegenerationDuration,
    property = 'energy',
    maxProperty = 'maxEnergy'
  })
end

local function InteractCollisionController(parent)
  local LOS = require 'modules.line-of-sight'
  local los = LOS()
  local losFilter = function(item)
    local matches = CollisionGroups.matches
    return matches(item.group, 'obstacle')
  end

  local isWithinLineOfSight = function(p, o)
    local nearestX, nearestY = Math.nearestBoxPoint(p.x, p.y, o.x, o.y, o.w, o.h)
    return los(p.x, p.y, nearestX, nearestY, losFilter)
  end

  local interactCollisionFilter = function(item)
    local p = parent
    local o = item
    local pickupRadius = parent.stats:get('pickupRadius')
    local isInteractable = CollisionGroups.matches(item.group, 'interact')
      and Math.isRectangleWithinRadius(p.x, p.y, pickupRadius, o.x, o.y, o.w, o.h)
      and isWithinLineOfSight(parent, item)

    if isInteractable then
      return true
    end

    return false
  end

   -- player interact collision
  Component.create({
    group = 'all',
    update = function(self)
      local p = parent
      local size = p.stats:get('pickupRadius') * 2

      local collisionWorlds = require 'components.collision-worlds'
      gsa('clearInteractableList')
      local items,len = collisionWorlds.gui:queryRect(parent.x - size/2, parent.y - size/2, size, size, interactCollisionFilter)
      for i=1, len do
        local it = items[i]
        gsa('setInteractable', it.parent)
      end
    end
  }):setParent(parent)
end

local Player = {
  id = 'PLAYER',
  autoSave = config.autoSave,
  class = 'player',
  group = groups.all,
  x = startPos.x,
  y = startPos.y,
  facingDirectionX = 1,
  facingDirectionY = 1,

  showHealing = true,
  inherentStats = {
    pickupRadius = 3 * config.gridSize,
    health = 1,
    energy = 1,
  },
  baseStats = function(self)
    local currentStats = self.stats and {
      health = self.stats:get('health'),
      energy = self.stats:get('energy'),
    }
    local inherentStats = Object.assign({}, self.inherentStats, currentStats)
    inherentStats.__index = inherentStats
    return setmetatable({
      energyRegeneration = 1,
      maxHealth = 200,
      maxEnergy = 100,
      moveSpeed = 80,
      lightRadius = 85,
    }, inherentStats)
  end,
  attackRecoveryTime = 0,

  zones = {},

  -- collision properties
  h = 1,
  w = 1,
  mapGrid = nil,

  init = function(self)
    local parent = self
    local state = {
      environmentInteractHovered = nil
    }
    self.state = state

    Component.addToGroup(self, groups.character)
    local Vec2 = require 'modules.brinevector'
    Component.addToGroup('PLAYER_DEFAULT_FORCE', 'gravForce', {
      magnitude = Vec2(),
      actsOn = 'PLAYER'
    })
    self.listeners = {
      msgBus.on(msgBus.GENERATE_LOOT, function(msgValue)
        local LootGenerator = require'components.loot-generator.loot-generator'
        local x, y, item = unpack(msgValue)
        if not item then
          return
        end
        LootGenerator.create({
          x = x,
          y = y,
          item = item,
          rootStore = rootState
        }):setParent(parent)
      end),

      msgBus.on('QUEST_LOG_TOGGLE', function()
        local activeLog = Component.get('QuestLog')
        if activeLog then
          activeLog:delete(true)
        else
          local QuestLog = require 'components.hud.quest-log'
          local cameraWidth = camera:getSize(true)
          local uiWidth = 160
          local offset = 0
          QuestLog.create({
            id = 'QuestLog',
            x = cameraWidth - uiWidth - offset,
            y = 110,
            width = uiWidth,
            height = 200,
          })
        end
      end),

      msgBus.on(msgBus.INVENTORY_TOGGLE, function()
        local activeInventory = Component.get('MENU_INVENTORY')
        if (not activeInventory) then
          local rootState = globalState.gameState
          Inventory.create({
            rootStore = rootState,
            slots = function()
              return rootState:get().inventory
            end
          }):setParent(self.hudRoot)
        elseif activeInventory then
          activeInventory:delete(true)
        end
      end),

      msgBus.on(msgBus.PASSIVE_SKILLS_TREE_TOGGLE, function()
        local PassiveTree = require 'components.player.passive-tree'
        PassiveTree.toggle()
      end),

      msgBus.on('PLAYER_PORTAL_OPEN', function(position)
        if self.inBossBattle then
          msgBus.send(msgBus.PLAYER_ACTION_ERROR, 'we cannot portal during boss')
          return
        end

        position = position or
          -- default to player position
          {x = self.x, y = self.y}

        if Component.get('HomeBase') then
          msgBus.send('PLAYER_ACTION_ERROR', 'Cannot do that here')
          return
        end

        local Portal = require 'components.portal'
        Portal.create({
          id = 'PlayerPortal',
          x = position.x,
          y = position.y - 18,
          location = {
            tooltipText = 'portal home',
            from = 'player'
          }
        })

        gsa('setPlayerPortalInfo', {
          position = position,
          mapId = globalState.activeLevel.mapId
        })
      end),

      msgBus.on(msgBus.KEY_DOWN, function(v)
        local key = v.key
        local keyMap = userSettings.keyboard

        if (keyMap.QUEST_LOG_TOGGLE == key) and (not v.hasModifier) then
          msgBus.send('QUEST_LOG_TOGGLE')
        end

        if (keyMap.INVENTORY_TOGGLE == key) and (not v.hasModifier) then
          msgBus.send(msgBus.INVENTORY_TOGGLE)
        end

        if (keyMap.MAP_TOGGLE == key) and (not v.hasModifier) then
          msgBus.send('MAP_TOGGLE')
        end

        if (keyMap.PORTAL_OPEN == key) and (not v.hasModifier) then
          msgBus.send('PLAYER_PORTAL_OPEN')
        end

        if (keyMap.PAUSE_GAME == key) and (not v.hasModifier) then
          msgBus.send(msgBus.PAUSE_GAME_TOGGLE)
        end

        if (keyMap.PASSIVE_SKILLS_TREE_TOGGLE == key) and (not v.hasModifier) then
          msgBus.send(msgBus.PASSIVE_SKILLS_TREE_TOGGLE)
        end
      end),

      msgBus.on(msgBus.PLAYER_HEAL_SOURCE_ADD, function(v)
        HealSource.add(self, v)
      end),

      msgBus.on(msgBus.PLAYER_HEAL_SOURCE_REMOVE, function(v)
        HealSource.remove(self, v.source)
      end),

      msgBus.on(msgBus.PLAYER_DISABLE_ABILITIES, function(msg)
        self.clickDisabled = msg
      end),

      msgBus.on(msgBus.PLAYER_LEVEL_UP, function(msg)
        local tick = require 'utils.tick'
        local fx = ParticleFx.Basic.create({
          x = self.x,
          y = self.y + 10,
          duration = 1,
          width = 4
        }):setParent(self)
        msgBus.send(msgBus.PLAYER_FULL_HEAL)
      end),

      msgBus.on(msgBus.DROP_ITEM_ON_FLOOR, function(item)
        return msgBus.send(
          msgBus.GENERATE_LOOT,
          {self.x, self.y, item}
        )
      end),

    }
    connectAutoSave(self)
    self.hudRoot = Component.create({
      group = groups.hud
    })
    local Hud = require 'components.hud.hud'
    Hud.create({
      player = self,
      rootStore = globalState.gameState
    }):setParent(self.hudRoot)
    connectInventory()
    self.onDamageTaken = function(self, actualDamage, actualNonCritDamage, criticalMultiplier)
      if (actualDamage > 0) then
        msgBus.send(msgBus.PLAYER_HIT_RECEIVED, actualDamage)
      end
    end

    self.rootStore = globalState.gameState
    self.dir = DIRECTION_RIGHT

    self.animations = {
      idle = animationFactory:new({
        'player/idle-0',
        'player/idle-1',
        'player/idle-2',
        'player/idle-3',
        'player/idle-4'
      }):setDuration(1.25),
      run = animationFactory:new({
        'player/run-0',
        'player/run-1',
        'player/run-2',
        'player/run-3',
      })
    }

    -- set default animation since its needed in the draw method
    self.animation = self.animations.idle

    local collisionW, collisionH = self.animations.idle:getSourceSize()
    local collisionOffX, collisionOffY = self.animations.idle:getSourceOffset()
    self.colObj = self:addCollisionObject(
      'player',
      self.x,
      self.y,
      collisionW,
      14,
      collisionOffX,
      5
    ):addToWorld(colMap)
    self.localCollision = self:addCollisionObject(
      'player',
      self.x,
      self.y,
      self.colObj.w,
      self.colObj.h,
      self.colObj.ox,
      self.colObj.oy
    ):addToWorld(collisionWorlds.player)

    InteractCollisionController(self)

    WeaponCore.create({
      x = self.x,
      y = self.y
    }):setParent(self)

    msgBus.send(msgBus.PLAYER_INITIALIZED)

    self.gameId = globalState.gameState:getId()
    EventLog.compact(self.gameId)
      :next(function()
        EventLog.start(self.gameId)
      end, function(err)
        msgBus.send('LOG_ERROR', err)
      end)
      :next(nil, function(err)
        msgBus.send('LOG_ERROR', err)
      end)
  end
}

function Player.updatePlayerModifiers(self)
  msgBus.send(msgBus.PLAYER_UPDATE_START)
  local Grid = require 'utils.grid'
  local gameState = require 'main.global-state'.gameState
  Grid.forEach(gameState:get().equipment, function(item)
    if (not item) then
      return
    end
    local itemSystem = require 'components.item-inventory.items.item-system'
    for k,v in pairs(itemSystem.getDefinition(item).baseModifiers) do
      self.stats:add(k, v)
    end
  end)
  PassiveTree = require 'components.player.passive-tree'
  PassiveTree.calcModifiers()
end

local function handleMovement(self, dt)
  local keyMap = userSettings.keyboard
  local totalMoveSpeed = self.stats:get('moveSpeed')

  if self.attackRecoveryTime > 0 then
    totalMoveSpeed = 0
  end

  local moveAmount = totalMoveSpeed * dt
  local origx, origy = self.x, self.y
  local mx, my = camera:getMousePosition()
  local mDx, mDy = Position.getDirection(self.x, self.y, mx, my)

  local nextX, nextY = self.x, self.y
  self.dir = mDx > 0 and DIRECTION_RIGHT or DIRECTION_LEFT

  -- MOVEMENT
  local inputX, inputY = 0, 0
  if (not self.cutSceneMode) then
    if love.keyboard.isDown(keyMap.MOVE_RIGHT) then
      inputX = 1
    end

    if love.keyboard.isDown(keyMap.MOVE_LEFT) then
      inputX = -1
    end

    if love.keyboard.isDown(keyMap.MOVE_UP) then
      inputY = -1
    end

    if love.keyboard.isDown(keyMap.MOVE_DOWN) then
      inputY = 1
    end
  end

  local vx, vy = Position.getDirection(0, 0, inputX, inputY)
  local gravForces = Component.groups.gravForce.getAll()
  local forceX, forceY = 0,0
  for _,v in pairs(gravForces) do
    if v.actsOn == 'PLAYER' then
      forceX = forceX + v.magnitude.x
      forceY = forceY + v.magnitude.y
    end
  end
  local dx, dy = (vx + forceX) * moveAmount,
    (vy + forceY) * moveAmount

  if self.mapGrid then
    local Grid = require 'utils.grid'
    local Position = require 'utils.position'
    local gridX, gridY = Position.pixelsToGridUnits(nextX, nextY, config.gridSize)
    local cellData = Grid.get(self.mapGrid, gridX, gridY)
    local slope = cellData and cellData.slope or 0
    dy = dy + (dx * slope)
  end

  nextX = nextX + dx
  nextY = nextY + dy

  self.facingDirectionX = mDx
  self.facingDirectionY = mDy
  self.moveDirectionX = vx
  self.moveDirectionY = vy

  return nextX, nextY, totalMoveSpeed
end

local function handleAnimation(self, dt, nextX, nextY, moveSpeed)
  local moving = self.x ~= nextX or self.y ~= nextY

  -- ANIMATION STATES
  if moving then
    self.animation = self.animations.run
      :setDuration(0.4 - (moveSpeed * 0.00004))
      :update(dt)
  else
    self.animations.run:reset()
    self.animation = self.animations.idle
      :update(dt)
  end
end

local function handleAbilities(self, dt)
  local mouseInputMap = userSettings.mouseInputMap
  local keyMap = userSettings.keyboard
  -- ACTIVE_ITEM_1
  local isItem1Activate = love.keyboard.isDown(keyMap.ACTIVE_ITEM_1)
  if not self.clickDisabled and isItem1Activate then
    msgBus.send(msgBus.PLAYER_USE_SKILL, 'ACTIVE_ITEM_1')
  end

  -- ACTIVE_ITEM_2
  local isItem2Activate = love.keyboard.isDown(keyMap.ACTIVE_ITEM_2)
  if not self.clickDisabled and isItem2Activate then
    msgBus.send(msgBus.PLAYER_USE_SKILL, 'ACTIVE_ITEM_2')
  end

  -- only disable equipment skills since we want to allow potions to still be used
  if self.clickDisabled or self.rootStore:get().activeMenu then
    return
  end

  local isSkill1Activate = love.keyboard.isDown(keyMap.SKILL_1) or
    love.mouse.isDown(mouseInputMap.SKILL_1)
  local isSkill2Activate = love.keyboard.isDown(keyMap.SKILL_2) or
    love.mouse.isDown(mouseInputMap.SKILL_2)
  local isSkill3Activate = love.keyboard.isDown(keyMap.SKILL_3) or
    love.mouse.isDown(mouseInputMap.SKILL_3)
  local isSkill4Activate = love.keyboard.isDown(keyMap.SKILL_4) or
    love.mouse.isDown(mouseInputMap.SKILL_4)
  local isMoveBoostActivate = love.keyboard.isDown(keyMap.MOVE_BOOST) or
    (mouseInputMap.MOVE_BOOST and love.mouse.isDown(mouseInputMap.MOVE_BOOST))
  local isRequestingToTriggerAction = isSkill1Activate or isSkill2Activate or isSkill3Activate or isSkill4Activate
  local isInteractButton = love.mouse.isDown(1)
  local canUseAbility =
    (self.isAlreadyAttacking and isRequestingToTriggerAction) or
    InputContext.contains('any')
  self.isAlreadyAttacking = canUseAbility
  if canUseAbility then
    -- SKILL_1
    if isSkill1Activate then
      msgBus.send(msgBus.PLAYER_USE_SKILL, 'SKILL_1')
    end

    -- SKILL_2
    if isSkill2Activate then
      msgBus.send(msgBus.PLAYER_USE_SKILL, 'SKILL_2')
    end

    -- SKILL_3
    if isSkill3Activate then
      msgBus.send(msgBus.PLAYER_USE_SKILL, 'SKILL_3')
    end

    -- SKILL_4
    if isSkill4Activate then
      msgBus.send(msgBus.PLAYER_USE_SKILL, 'SKILL_4')
    end
  end

  -- MOVE_BOOST
  if isMoveBoostActivate then
    msgBus.send(msgBus.PLAYER_USE_SKILL, 'MOVE_BOOST')
  end
end

local min = math.min

function Player.handleMapCollision(self, nextX, nextY)
  -- dynamically get the current animation frame's height
  local sx, sy, sw, sh = self.animation.sprite:getViewport()
  local w,h = sw, sh

  local actualX, actualY, cols, len = self.colObj:move(nextX, nextY, collisionFilter)
  self.x = actualX
  self.y = actualY
  self.h = h
  self.w = w

  self.localCollision:move(actualX, actualY)
end

local function zoneCollisionFilter()
  return 'cross'
end

local function handleBossMode(self)
  -- destroy active portal
  local playerPortal = Component.get('playerPortal')
  if playerPortal then
    playerPortal:delete(true)
  end
end

local function updateLightWorld(camera)
  local cameraTranslateX, cameraTranslateY = camera:getPosition()
  local cWidth, cHeight = camera:getSize(true)
  local lightWorld = Component.get('lightWorld')
  lightWorld:setPosition(-cameraTranslateX + cWidth/2, -cameraTranslateY + cHeight/2)
end

local function resetInteractStates(self)
  self.state.environmentInteractHovered = nil
end

function Player.update(self, dt)

  self:updatePlayerModifiers()
  if (not self.recentlyCreated) then
    self.recentlyCreated = true
    msgBus.send(msgBus.PLAYER_FULL_HEAL)
  end

  local healthRegen = self.stats:get('healthRegeneration')
  if self.prevHealthRegeneration ~= healthRegen then
    self.prevHealthRegeneration = healthRegen
    updateHealthRegeneration(healthRegen)
  end

  local energyRegen = self.stats:get('energyRegeneration')
  if self.prevEnergyRegeneration ~= energyRegen then
    self.prevEnergyRegeneration = energyRegen
    updateEnergyRegeneration(energyRegen)
  end

  if self.inBossBattle then
    handleBossMode(self)
  end

  local hasPlayerLost = self.stats:get('health') <= 0
  if hasPlayerLost then
    if Component.get('PLAYER_LOSE') then
      return
    end
    local PlayerLose = require 'components.player-lose'
    PlayerLose.create()
    return
  end

  self.attackRecoveryTime = self.attackRecoveryTime - dt
  local nextX, nextY, totalMoveSpeed = handleMovement(self, dt)
  handleAnimation(self, dt, nextX, nextY, totalMoveSpeed)

  self:handleMapCollision(
    nextX,
    nextY
  )

  -- update camera to follow player
  if (not self.cutSceneMode) then
    handleAbilities(self, dt)
    camera:setPosition(self.x, self.y, userSettings.camera.speed)
  end

  updateLightWorld(camera)
  resetInteractStates(self)
end

local function drawShadow(self, sx, sy, ox, oy)
  -- SHADOW
  love.graphics.setColor(0,0,0,0.25)
  self.animation:draw(
    self.x,
    self.y + self.h/2,
    math.rad(self.angle),
    sx,
    -sy / 4,
    ox,
    oy
  )
end

local function drawDebug(self)
  if config.collisionDebug then
    local c = self.colObj
    love.graphics.setColor(0,0,1,0.8)
    love.graphics.circle('fill', self.x, self.y, 4)

    love.graphics.setColor(0,1,0)
    local c1 = self.colObj
    local x, y = c1:getPositionWithOffset()
    love.graphics.rectangle('line', x, y, c1.w, c1.h)


    love.graphics.setColor(1,0.5,1)
    local Position = require 'utils.position'
    local gridSize = 16
    local gridX, gridY = Position.pixelsToGridUnits(self.x, self.y, gridSize)
    love.graphics.rectangle('line', gridX * gridSize, gridY * gridSize, gridSize, gridSize)
  end
end

function Player.draw(self)
  -- draw light around player
  Component.get('lightWorld'):addLight(
    self.x, self.y,
    self.stats:get('lightRadius'),
    {1,1,1}
  )

  local ox, oy = self.animation:getSourceOffset()
  local scaleX, scaleY = 1 * self.dir, 1

  drawShadow(self, scaleX, scaleY, ox, oy)

  love.graphics.setColor(1,1,1)
  love.graphics.draw(
    animationFactory.atlas,
    self.animation.sprite,
    self.x,
    self.y,
    math.rad(self.angle),
    scaleX,
    scaleY,
    ox,
    oy
  )

  drawDebug(self)
end

Player.drawOrder = function(self)
  return self.group:drawOrder(self) + 1
end

Player.final = function(self)
  msgBus.off(self.listeners)
  self.hudRoot:delete(true)
end

return Component.createFactory(Player)
