local Component = require 'modules.component'
local Gui = require 'components.gui.gui'
local msgBus = require 'components.msg-bus'
local msgBus = require 'components.msg-bus'
local AnimationFactory = require 'components.animation-factory'
local font = require 'components.font'
local GuiText = require 'components.gui.gui-text'
local Color = require 'modules.color'

local MenuButtons = {
  group = Component.groups.hud
}

local tooltipText = GuiText.create({
  font = font.primary.font
})

local function calcPulse(freq, time)
  return 0.5 * math.sin(freq * time) + 0.5
end

local function showTooltip(x, y, text)
  local textWidth, textHeight = GuiText.getTextSize(text, tooltipText.font)
  local padding = 4
  local Color = require 'modules.color'
  local actualY = y - textHeight - (padding * 2)
  love.graphics.setColor(Color.DARK_GRAY)
  love.graphics.rectangle('fill', x, actualY, textWidth + (padding * 2), textHeight + padding)
  tooltipText:add(text, Color.WHITE, x + padding, actualY + padding)
end

function MenuButtons.init(self)
  local parent = self

  local buttons = {
    {
      displayValue = 'Main Menu (esc)',
      normalAni = AnimationFactory:newStaticSprite('gui-home-button'),
      hoverAni = AnimationFactory:newStaticSprite('gui-home-button--hover'),
      onClick = function()
        msgBus.send(msgBus.TOGGLE_MAIN_MENU)
      end
    },
    {
      displayValue = 'Inventory (i)',
      normalAni = AnimationFactory:newStaticSprite('gui-inventory-button'),
      hoverAni = AnimationFactory:newStaticSprite('gui-inventory-button--hover'),
      onClick = function()
        msgBus.send(msgBus.INVENTORY_TOGGLE)
      end
    },
    {
      displayValue = 'Skill Tree (o)',
      normalAni = AnimationFactory:newStaticSprite('gui-skill-tree-button'),
      hoverAni = AnimationFactory:newStaticSprite('gui-skill-tree-button--hover'),
      badge = function()
        local PlayerPassiveTree = require 'components.player.passive-tree'
        local unusedSkillPoints = PlayerPassiveTree.getUnusedSkillPoints()
        return unusedSkillPoints
      end,
      onClick = function()
        msgBus.send(msgBus.PASSIVE_SKILLS_TREE_TOGGLE)
      end
    },
    {
      displayValue = 'Quests (u)',
      normalAni = AnimationFactory:newStaticSprite('gui-quest-log-button'),
      hoverAni = AnimationFactory:newStaticSprite('gui-quest-log-button--hover'),
      badge = function()
        return 0
      end,
      onClick = function()
        msgBus.send('QUEST_LOG_TOGGLE')
      end
    }
  }

  for index=1, #buttons do
    local b = buttons[index]
    local ox, oy = b.normalAni:getOffset()
    local spriteWidth, spriteHeight = b.normalAni:getSourceSize()
    local drawIndex = index - 1
    local margin = 2
    local spacing = (drawIndex * spriteWidth) + (drawIndex * margin)
    Gui.create({
      x = parent.x + spacing,
      y = parent.y,
      group = Component.groups.hud,
      type = Gui.types.BUTTON,
      onClick = b.onClick,
      onUpdate = function(self, dt)
        self.w, self.h = spriteWidth, spriteHeight
        self.clock = (self.clock or 0) + dt

        local badgeValue = b.badge and b.badge() or 0
        badgeValue = (badgeValue > 0) and badgeValue or nil
        if badgeValue and (badgeValue > 9) then
          badgeValue = '9+'
        end
        self.showBadge = badgeValue ~= nil
        love.graphics.setColor(1,1,1)
        self.pulse = calcPulse(4, self.clock)
        self.yPos = self.showBadge and (self.y - (self.pulse * 2)) or self.y

        if self.showBadge then
          local hudTextSmallLayer = Component.get('hudTextSmallLayer')
          local x, y = self.x + spriteWidth - 3, self.yPos
          hudTextSmallLayer:add(
            badgeValue,
            Color.WHITE,
            x,
            y
          )
        end
      end,
      draw = function(self)
        local highlightColor = Color.YELLOW

        local animation = b.normalAni
        local drawX, drawY = self.x + math.floor(self.w/2), self.yPos + math.floor(self.h/2)
        love.graphics.setColor(Color.WHITE)
        b.normalAni:draw(drawX, drawY)

        if self.hovered or self.showBadge then
          if self.hovered then
            love.graphics.setColor(Color.WHITE)
          else
            love.graphics.setColor(Color.multiplyAlpha(highlightColor, self.pulse))
          end
          b.hoverAni:draw(drawX, drawY)
        end

        if self.hovered then
          showTooltip(drawX, drawY, b.displayValue)
        end
      end
    }):setParent(self)
  end
end

return Component.createFactory(MenuButtons)