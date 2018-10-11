local itemSystem = require 'components.item-inventory.items.item-system'
local msgBus = require 'components.msg-bus'
local extend = require 'utils.object-utils'.extend
local fancyRandom = require 'utils.fancy-random'
local Color = require 'modules.color'

local module = itemSystem.registerModule({
  name = 'stat',
  type = itemSystem.moduleTypes.MODIFIERS,
  active = function(_, props, state)
    msgBus.on(msgBus.PLAYER_STATS_NEW_MODIFIERS, function(mods)
      if (not state.equipped) then
        return msgBus.CLEANUP
      end
      for k,v in pairs(props) do
        mods[k] = mods[k] + v
      end
      return mods
    end, 1)
  end,
  tooltip = function(_, props)
    return {
      type = 'statsList',
      data = props
    }
  end
})

--[[
  modifiers may be passed in as actual values or ranges. If a range is provided, then it will be
  converted to a single value with a randomizer
]]
return function(props)
  for prop,value in pairs(props) do
    local isRange = type(value) == 'table'
    if isRange then
      props[prop] = fancyRandom(value[1], value[2], 2)
    end
  end
  return module(props)
end