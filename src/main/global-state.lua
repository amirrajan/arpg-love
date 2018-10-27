local Component = require 'modules.component'
local sceneManager = require 'scene.manager'
local groups = require 'components.groups'
local msgBus = require 'components.msg-bus'
local CreateStore = require 'components.state.state'
local Lru = require 'utils.lru'

local function newStateStorage()
  return Lru.new(100)
end

local globalState = {
  activeScene = nil,
  backgroundColor = {0.2,0.2,0.2},
  sceneStack = sceneManager,
  gameState = CreateStore(),
  stateSnapshot = {
    serializedStateByMapId = newStateStorage(),
    serializeAll = function(self, mapId)
      local statesByClass = {}
      local collisionGroups = require 'modules.collision-groups'
      local f = require 'utils.functional'
      local classesToMatch = collisionGroups.create(
        collisionGroups.ai,
        collisionGroups.floorItem,
        collisionGroups.mainMap,
        collisionGroups.environment,
        'portal'
      )
      local components = f.reduce({
        groups.all.getAll(),
        groups.firstLayer.getAll(),
        Component.groups.disabled.getAll()
      }, function(components, groupComponents)
        for _,c in pairs(groupComponents) do
          if collisionGroups.matches(c.class or '', classesToMatch) then
            components[c:getId()] = c
          end
        end
        return components
      end, {})

      -- serialize states
      for _,c in pairs(components) do
        local list = statesByClass[c.class]
        if (not list) then
          list = {}
          statesByClass[c.class] = list
        end
        table.insert(list, {
          blueprint = Component.getBlueprint(c),
          state = c:serialize()
        })
      end

      self.serializedStateByMapId:set(mapId, setmetatable(statesByClass, {
        __index = function()
          return {}
        end
      }))

      consoleLog('dungeon serialized', mapId)
    end,
    consumeSnapshot = function(self, mapId)
      return self.serializedStateByMapId:get(mapId)
    end,
    clearAll = function(self)
      self.serializedStateByMapId = newStateStorage()
    end
  }
}

msgBus.on(msgBus.NEW_GAME, function()
  globalState.stateSnapshot:clearAll()
end, 1)

return globalState