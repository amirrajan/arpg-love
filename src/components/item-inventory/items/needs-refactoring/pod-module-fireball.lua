local itemConfig = require("components.item-inventory.items.config")
local config = require 'config.config'
local msgBus = require("components.msg-bus")
local itemSystem =require("components.item-inventory.items.item-system")
local Color = require 'modules.color'
local collisionGroups = require 'modules.collision-groups'
local functional = require("utils.functional")
local groups = require 'components.groups'

local mathFloor = math.floor

local enemiesPerDamageIncrease = 30
local maxBonusDamage = 2
local baseDamage = 2

local function onEnemyDestroyedIncreaseDamage(self)
	local s = self.state
	s.enemiesKilled = s.enemiesKilled + 1
	s.bonusDamage = mathFloor(s.enemiesKilled / enemiesPerDamageIncrease)
	if s.bonusDamage > maxBonusDamage then
		s.bonusDamage = maxBonusDamage
	end
	self.flatDamage = s.bonusDamage
end

local function statValue(stat, color, type)
	local sign = stat >= 0 and "+" or "-"
	return {
		color, sign..stat..' ',
		{1,1,1}, type
	}
end

local function concatTable(a, b)
	for i=1, #b do
		local elem = b[i]
		table.insert(a, elem)
	end
	return a
end

local MUZZLE_FLASH_COLOR = {Color.rgba255(232, 187, 27, 1)}
local muzzleFlashMessage = {
	color = MUZZLE_FLASH_COLOR
}

return itemSystem.registerType({
	type = 'action-module-fireball',

	create = function()
		return {
			stackSize = 1,
			maxStackSize = 1,

			state = {
				baseDamage = baseDamage,
				bonusDamage = 0,
				enemiesKilled = 0,
			},

			-- static properties
			weaponDamage = baseDamage,
			experience = 0
		}
	end,

	properties = {
		sprite = "weapon-module-fireball",
		title = 'tz-819 mortar',
		rarity = itemConfig.rarity.LEGENDARY,
		baseDropChance = 1,
		category = itemConfig.category.ACTION_MODULE,

		levelRequirement = 3,
		actionSpeed = 0.4,
		energyCost = function(self)
			return 2
		end,

		upgrades = {
			{
				sprite = 'item-upgrade-placeholder-unlocked',
				title = 'Daze',
				description = 'Attacks slow the target',
				experienceRequired = 45,
				props = {
					knockBackDistance = 50
				}
			},
			{
				sprite = 'item-upgrade-placeholder-unlocked',
				title = 'Scorch',
				description = 'Chance to create an area of ground fire, dealing damage over time to those who step into it.',
				experienceRequired = 135,
				props = {
					duration = 3,
					minDamagePerSecond = 1,
					maxDamagePerSecond = 3,
				}
			}
		},

		tooltip = function(self)
			local _state = self.state
			local stats = {
				{
					Color.WHITE, '\nWhile equipped: \nPermanently gain +1 damage for every 10 enemies killed.\n',
					Color.CYAN, _state.enemiesKilled, Color.WHITE, ' enemies killed'
				}
			}
			return functional.reduce(stats, function(combined, textObj)
				return concatTable(combined, textObj)
			end, {})
		end,

		onEquip = function(self)
			local state = itemSystem.getState(self)
			local definition = itemSystem.getDefinition(self)
			local upgrades = definition.upgrades

			local listeners = {
				msgBus.on(msgBus.ENEMY_DESTROYED, function()
					onEnemyDestroyedIncreaseDamage(self)
				end)
			}
			msgBus.on(msgBus.EQUIPMENT_UNEQUIP, function(item)
				if item == self then
					msgBus.off(listeners)
					return msgBus.CLEANUP
				end
			end)

			state.onHit = function(attack, hitMessage)
				local target = hitMessage.parent
				local up1Ready = msgBus.send(msgBus.ITEM_CHECK_UPGRADE_AVAILABILITY, {
					item = self,
					level = 1
				})
				if up1Ready then
					local up1 = upgrades[1]
					msgBus.send(msgBus.CHARACTER_HIT, {
						parent = target,
						statusIcon = 'status-slow',
						duration = 1,
						modifiers = {
							moveSpeed = function(t)
								return t.moveSpeed * -0.5
							end
						},
						source = definition.title
					})
				end
				return hitMessage
			end

			local function handleUpgrade2(attack)
				local up2Ready = msgBus.send(msgBus.ITEM_CHECK_UPGRADE_AVAILABILITY, {
					item = self,
					level = 2
				})
				if up2Ready then
					local up2 = upgrades[2]
					local GroundFlame = require 'components.particle.ground-flame'
					local x, y = attack.x, attack.y
					local width, height = 16, 16
					GroundFlame.create({
						group = groups.all,
						x = x,
						y = y,
						width = width,
						height = height,
						gridSize = config.gridSize,
						duration = up2.props.duration
					})

					local collisionWorlds = require 'components.collision-worlds'
					local tick = require 'utils.tick'
					local tickCount = 0
					local timer
					timer = tick.recur(function()
						tickCount = tickCount + 1
						if tickCount >= up2.props.duration then
							timer:stop()
						end
						collisionWorlds.map:queryRect(
							x - config.gridSize,
							y - config.gridSize,
							width * 2,
							height * 2,
							function(item)
								if collisionGroups.matches(item.group, 'enemyAi environment') then
									msgBus.send(msgBus.CHARACTER_HIT, {
										parent = item.parent,
										damage = math.random(
											up2.props.minDamagePerSecond,
											up2.props.maxDamagePerSecond
										)
									})
								end
							end
						)
					end, 1)
				end
			end
			state.final = handleUpgrade2
		end,

		onActivate = function(self)
			local toSlot = itemSystem.getDefinition(self).category
			msgBus.send(msgBus.EQUIPMENT_SWAP, self)
		end,

		onActivateWhenEquipped = function(self, props)
			local Fireball = require 'components.fireball'
			local F = require 'utils.functional'
			props.minDamage = 0
			props.maxDamage = 0
			props.cooldown = 0.7
			props.startOffset = 26
			props.onHit = itemSystem.getState(self).onHit
			props.final = F.wrap(
				props.final,
				itemSystem.getState(self).final
			)
			msgBus.send(msgBus.PLAYER_WEAPON_MUZZLE_FLASH, muzzleFlashMessage)

			local Sound = require 'components.sound'
			love.audio.play(Sound.functions.fireBlast())
			return Fireball.create(props)
		end
	}
})