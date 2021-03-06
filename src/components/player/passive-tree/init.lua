local Component = require 'modules.component'
local Color = require 'modules.color'
local config = require 'config.config'
local MenuManager = require 'modules.menu-manager'
local SkillTreeEditor = require 'components.skill-tree-editor'
local msgBus = require 'components.msg-bus'
local memoize = require 'utils.memoize'
local Db = require 'modules.database'

local function getSaveFileName(gameId)
  return gameId..'/passive-tree'
end

local onHitModifiers = {}
local updateModifiers = {}
local onDamageReceivedModifiers = {}
local stateByNodeId = {
  get = function(self, nodeId)
    local state = self[nodeId]
    if (not state) then
      state = {}
      self[nodeId] = state
    end
    return state
  end
}
local statModifiersByTypeAndValue = {
  get = function(self, prop, value)
    local fnsByType = self[prop]
    if (not fnsByType) then
      fnsByType = {}
      self[prop] = fnsByType
    end

    local modFn = fnsByType[value]
    if (not modFn) then
      modFn = function(stats)
        return value * stats[prop]
      end
      fnsByType[value] = modFn
    end

    return modFn
  end
}

msgBus.on(msgBus.CHARACTER_HIT, function(msg)
  if msg.itemSource then
    for _,handler in pairs(onHitModifiers) do
      handler(msg)
    end
  end
  return msg
end, 2)

msgBus.on(msgBus.PLAYER_UPDATE_START, function(dt)
  for _,handler in pairs(updateModifiers) do
    handler(dt)
  end
end)

msgBus.on(msgBus.DAMAGE_RECEIVED, function(msg)
  for _,handler in pairs(onDamageReceivedModifiers) do
    handler(msg)
  end
  return msg
end, 2)

local modifierHandlers = {
  lightningRod = function(nodeId, data, modifiers)
    onHitModifiers[nodeId] = function(hitMsg)
      msgBus.send(msgBus.CHARACTER_HIT, {
        parent = hitMsg.parent,
        duration = 0.5,
        modifiers = {
          shocked = 1,
        },
        source = 'INITIATE_SHOCK'
      })
      local multiplier = data.value.value
      hitMsg.lightningDamage = hitMsg.lightningDamage + (multiplier * hitMsg.damage)
    end
    return modifiers
  end,
  bloodRage = function(nodeId, data, modifiers)
    Component.get('PLAYER').stats:add('actionPower', function(self)
      local percentHealthMissing = 1 - self:get('health') / self:get('maxHealth')
      local totalBonusPercentage = data.value.bonus * percentHealthMissing * 100
      return self.actionPower * totalBonusPercentage
    end)
    return modifiers
  end,
  heavyStrike = function(nodeId, data, modifiers)
    onHitModifiers[nodeId] = function(hitMsg)
      local state = stateByNodeId:get(nodeId)
      state.hitCount = state.hitCount or 0
      state.hitSources = state.hitSources or {}
      local isNewSource = not state.hitSources[hitMsg.source]
      if isNewSource then
        state.hitCount = state.hitCount + 1
        if state.hitCount > 2 then
          state.isBigHit = true
          state.hitCount = 0
          state.hitSources = {}
        end
        state.hitSources[hitMsg.source] = true
        if state.hitCount == 1 then
          state.isBigHit = false
        end
      end
      if state.isBigHit then
        local percentBonusDamage = data.value.value
        hitMsg.criticalChance = 1
        hitMsg.criticalMultiplier = (hitMsg.criticalMultiplier or 0) + percentBonusDamage
      end
    end
    updateModifiers[nodeId] = function(dt)
      local uid = require 'utils.uid'
      local iconId = uid()
      local state = stateByNodeId:get(nodeId)
      Component.addToGroup(iconId, 'hudStatusIcons', {
        text = (state.hitCount or 0),
        icon = 'gui-skill-tree_node_heavy-strike'
      })
    end
    return modifiers
  end,
  dummyNode = function(_, _, modifiers)
    return modifiers
  end,
  maxHealthEnergy = function(nodeId, data, modifiers)
    modifiers
      :add('maxHealth', data.value.bonusHealth * modifiers.maxHealth)
      :add('maxEnergy', data.value.bonusEnergy * modifiers.maxEnergy)
    return modifiers
  end,
  percentEnergyRegen = function(nodeId, data, modifiers)
    modifiers
      :add('energyRegeneration', function(self)
        return self.energyRegeneration * data.value.percentBonus
      end)
  end,
  percentHealthRegen = function(nodeId, data, modifiers)
    modifiers
      :add('healthRegeneration', function(self)
        return self.healthRegeneration * data.value.percentBonus
      end)
  end,
  percentHybridRegen = function(nodeId, data, modifiers)
    modifiers
      :add('healthRegeneration', function(self)
        return self.healthRegeneration * data.value.percentHealthRegen
      end)
      :add('energyRegeneration', function(self)
        return self.energyRegeneration * data.value.percentEnergyRegen
      end)
      :add('energyRegeneration', function(self)
        local percentEnergyMissing = 1 - (self:get('energy') / self:get('maxEnergy'))
        return self.energyRegeneration * percentEnergyMissing
      end)
  end,
  statModifier = function(nodeId, data, modifiers)
    local prop = data.value.type
    local percentBonus = data.value.value
    local modFn = statModifiersByTypeAndValue:get(prop, percentBonus)
    return modifiers:add(prop, modFn)
  end,
  energySteal = function(nodeId, data)
    onDamageReceivedModifiers[nodeId] = function(msg)
      local leech = require 'components.player.passive-tree.passives.leech'
      leech(data, 'energy', 'maxEnergy', msg, msgBus)
    end
  end,
  lifeSteal = function(nodeId, data)
    onDamageReceivedModifiers[nodeId] = function(msg)
      local leech = require 'components.player.passive-tree.passives.leech'
      leech(data, 'health', 'maxHealth', msg, msgBus)
    end
  end
}

local PassiveTree = {}

local rootDir = 'saved-states'

function PassiveTree.getState(file)
  local Db = require 'modules.database'
  local result = Db.load(rootDir):get(file)
  return result
end

local calcModifiers = function(treeData)
  onHitModifiers = {}
  updateModifiers = {}
  onDamageReceivedModifiers = {}

  local nodeData = SkillTreeEditor.parseTreeData(treeData)
  local modifiers = Component.get('PLAYER').stats
  for nodeId,data in pairs(nodeData) do
    local dataType = data.value.type
    local modifierFunc = modifierHandlers[dataType] or
      modifierHandlers.statModifier
    modifierFunc(nodeId, data, modifiers)
  end
  return modifiers
end

function PassiveTree.calcModifiers()
  local gameState = require 'main.global-state'.gameState
  local saveDir = getSaveFileName(gameState:getId())
  local treeData = PassiveTree.getState(saveDir)
  return calcModifiers(treeData or {})
end

local getUnusedSkillPoints = memoize(function(treeData, totalSkillPointsAvailable)
  local nodeData = SkillTreeEditor.parseTreeData(treeData)
  local unusedSkillPoints = totalSkillPointsAvailable
  for _ in pairs(nodeData) do
    unusedSkillPoints = unusedSkillPoints - 1
  end
  return unusedSkillPoints
end)

function PassiveTree.getUnusedSkillPoints(treeData)
  local gameState = require 'main.global-state'.gameState
  local file = getSaveFileName(gameState:getId())
  treeData = treeData or PassiveTree.getState(file)
  local gameState = require 'main.global-state'.gameState
  -- start out with zero skill points at level 1
  local totalSkillPointsAvailable = gameState:get().level - 1
  return getUnusedSkillPoints(treeData or {}, totalSkillPointsAvailable)
end

function PassiveTree.deleteState(stateId)
  return Db.load(rootDir):delete(getSaveFileName(stateId))
end

function PassiveTree.toggle()
  if Component.get('passiveSkillsTree') then
    MenuManager.clearAll()
    return
  end

  local gameState = require 'main.global-state'.gameState
  local file = getSaveFileName(gameState:getId())
  local nodesFromSavedState = PassiveTree.getState(file)
  local editor = SkillTreeEditor.create({
    id = 'passiveSkillsTree',
    editorMode = 'PLAY_READ_ONLY',
    nodes = nodesFromSavedState,
    --[[
      NOTE: we need to update editor mode during both `onChange` and `onSerialize`
      since onSerialize is async which means there could be new changes that have
      not been saved yet.
    ]]
    onChange = function(self)
      self.editorMode = PassiveTree.getUnusedSkillPoints() > 0 and
        'PLAY' or
        'PLAY_UNSELECT_ONLY'
    end,
    onSerialize = function(self, serializedString, serialized)
      self.editorMode = PassiveTree.getUnusedSkillPoints(serialized) > 0 and
        'PLAY' or
        'PLAY_UNSELECT_ONLY'
      Db.load(rootDir):put(file, serialized)
        :next(function()
          print('passive tree saved')
        end)
    end
  }):setParent(
    Component.get('HUD')
  )
  Component.create({
    init = function(self)
      Component.addToGroup(self, 'gui')
    end,
    draw = function(self)
      local font = require 'components.font'.primary.font
      love.graphics.setColor(1,1,1)
      love.graphics.setFont(font)
      local text = {
        Color.WHITE,
        PassiveTree.getUnusedSkillPoints(),
        Color.WHITE,
        ' points left',
      }
      local GuiText = require 'components.gui.gui-text'
      local Position = require 'utils.position'
      local textWidth, textHeight = GuiText.getTextSize(text, font)
      local vWidth, vHeight = love.graphics.getWidth()/config.scale,
        love.graphics.getHeight()/config.scale
      local x = Position.boxCenterOffset(textWidth, textHeight, vWidth, vHeight)
      love.graphics.printf(
        text,
        x,
        20,
        200
      )
    end,
    drawOrder = function()
      return editor:drawOrder() + 1
    end
  }):setParent(editor)
  local msgBus = require 'components.msg-bus'
  msgBus.send(msgBus.TOGGLE_MAIN_MENU, false)
  MenuManager.clearAll()
  MenuManager.push(editor)
end

return PassiveTree