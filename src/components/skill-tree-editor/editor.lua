local Component = require 'modules.component'
local groups = require 'components.groups'
local msgBus = require 'components.msg-bus'
local msgBusMainMenu = require 'components.msg-bus-main-menu'
local Gui = require 'components.gui.gui'
local GuiText = require 'components.gui.gui-text'
local config = require 'config.config'
local Color = require 'modules.color'
local bump = require 'modules.bump'
local F = require 'utils.functional'
local nodeValueOptions = require 'components.skill-tree-editor.node-data-options'
local inputState = require 'main.inputs'.state
local Object = require 'utils.object-utils'
local noop = require 'utils.noop'
local rebuildTableBySortingKeys = require 'components.skill-tree-editor.rebuild-table-by-sorting-keys'

--[[
  Instructions:

  click - place a node
  click node - selects node. If a node is already selected, creates a connection between both nodes
  drag node - moves node
  'delete' key - deletes selected node or connection
  's' key - executes serialization function
]]

local mouseCollisionWorld = bump.newWorld(32)
local mouseCollisionObject = {}
local mouseCollisionSize = 50
local cellSize = 25
mouseCollisionWorld:add(mouseCollisionObject, 0, 0, mouseCollisionSize, mouseCollisionSize)

local debugTextLayer = GuiText.create({
  font = require 'components.font'.primary.font,
  drawOrder = function()
    return 10
  end
})

local TreeEditor = {
  debug = {
    -- connectionCount = true,
  },
  nodes = nil,
  nodeValueOptions = {},
  onChange = noop,
  onSerialize = noop,
  serialize = function(self)
    local ser = require 'utils.ser'
    local serializedTree = {}
    for nodeId in pairs(rebuildTableBySortingKeys(self.nodes)) do
      local node = Component.get(nodeId)
      serializedTree[nodeId] = node:serialize()
    end

    --[[
      Love's `love.filesystem.write` doesn't support writing to files in the source directory,
      therefore we must use the `io` module.
    ]]
    local serializedTreeAsString = ser(serializedTree)
    local isNewState = previousSerializedTreeAsString ~= serializedTreeAsString
    previousSerializedTreeAsString = serializedTreeAsString

    if isNewState then
      self:onSerialize(serializedTreeAsString, serializedTree)
    end
  end
}

local function snapToGrid(x, y)
  local Position = require 'utils.position'
  local gridX, gridY = Position.pixelsToGridUnits(x, y, cellSize)
  return Position.gridToPixels(gridX, gridY, cellSize)
end

local initialDx, initialDy = snapToGrid(1920/2, 1080/2)
local Enum = require 'utils.enum'
local editorModes = Enum({
  'EDIT',

  -- these modes are for in-game views
  'PLAY',
  'PLAY_READ_ONLY',
  'PLAY_UNSELECT_ONLY'
})
local state = {
  hoveredNode = nil,
  selectedNode = nil,
  movingNode = nil,
  hoveredConnection = nil,
  selectedConnection = nil,
  translate = {
    startX = 0,
    startY = 0,
    dx = 0,
    dy = 0,
    dxTotal = initialDx,
    dyTotal = initialDy
  },
  mx = 0,
  my = 0,
  editorMode = editorModes.EDIT,
}

function TreeEditor.getMode(self)
  local InputContext = require 'modules.input-context'
  if 'gui' == InputContext.get() then
    return
  end

  if (inputState.keyboard.keysPressed.space) then
    return 'TREE_PANNING'
  end

  if editorModes.EDIT == self.editorMode then
    if (state.hoveredNode or state.movingNode) and inputState.mouse.drag.isDragging then
      return 'NODE_MOVE'
    end

    if state.selectedNode and state.hoveredNode and (state.hoveredNode ~= state.selectedNode) then
      local hasConnection = self.nodes[state.selectedNode].connections[state.hoveredNode]
      if (not hasConnection) then
        return 'CONNECTION_CREATE'
      end
    end

    if (not state.hoveredNode) and (not state.hoveredConnection) then
      if (state.selectedNode or state.selectedConnection) then
        return 'CLEAR_SELECTIONS'
      end
      return 'NODE_CREATE'
    end

    if state.hoveredConnection then
      return 'CONNECTION_SELECTION'
    end
  end

  if state.hoveredNode then
    return 'NODE_SELECTION'
  end
end

local function getTranslate()
  return state.translate.dxTotal + state.translate.dx,
    state.translate.dyTotal + state.translate.dy
end

local function clearSelections()
  state.selectedNode = nil
  state.selectedConnection = nil
end

local playMode = {
  isNodeSelectable = function(nodeToCheck, nodeList, nodeValueOptions)
    local nodeValue = nodeToCheck.nodeValue
    local nodeData = nodeValueOptions[nodeValue]

    -- if any node has a selected connection, then it is selectable
    for id in pairs(nodeToCheck.connections) do
      if nodeList[id].selected then
        return true
      end
    end
    return false
  end,
  isNodeUnselectable = function(nodeToCheck, nodeList)
    local numSelectedSiblingNodes = 0
    for id in pairs(nodeToCheck.connections) do
      if nodeList[id].selected then
        numSelectedSiblingNodes = numSelectedSiblingNodes + 1
      end
      if numSelectedSiblingNodes > 1 then
        return false
      end
    end
    return true
  end,
  isConnectionToSelectableNode = function(fromNode, toNode)
    if editorModes.PLAY == state.editorMode then
      return fromNode.selected or toNode.selected
    end

    if (editorModes.PLAY_READ_ONLY == state.editorMode) or
      (editorModes.PLAY_UNSELECT_ONLY == state.editorMode) then
      return fromNode.selected and toNode.selected
    end
  end
}

-- creates a new node and adds it to the node tree
local function placeNode(root, nodeId, screenX, screenY, connections, nodeValue, selected, size)
  size = size or 1

  local node = Gui.create({
    id = nodeId,
    inputContext = 'treeNode',
    x = screenX,
    y = screenY,
    width = size,
    height = size,
    scale = 1,

    getMousePosition = function(self)
      local tx, ty = getTranslate()
      return love.mouse.getX() - tx,
        love.mouse.getY() - ty
    end,

    serialize = function(self)
      local dataRef = root.nodes[self:getId()]
      return {
        -- store coordinates as grid units
        x = dataRef.x / cellSize,
        y = dataRef.y / cellSize,
        size = nodeSize,
        connections = dataRef.connections,
        nodeValue = dataRef.nodeValue,
        selected = dataRef.selected
      }
    end,

    onPointerMove = function(self)
      -- in any non-edit mode, prevent selection if the node is read only
      if editorModes.EDIT ~= root.editorMode then
        local dataRef = root.nodes[self:getId()]
        local nodeData = root.nodeValueOptions[dataRef.nodeValue]
        local isReadOnly = (not nodeData) or nodeData.readOnly
        if isReadOnly then
          return
        end
      end

      state.hoveredNode = self:getId()
    end,
    onPointerLeave = function(self)
      state.hoveredNode = nil
    end,
    onUpdate = function(self)
      local dataRef = root.nodes[self:getId()]
      if (not dataRef) then
        self:delete(true)
        state.hoveredNode = nil
        state.selectedNode = nil
        return
      end
      local optionValue = root.nodeValueOptions[self.nodeValue]
      local size = optionValue and (optionValue.type == 'keystone') and (2 * cellSize) or (2 * cellSize)
      self.width, self.height = size, size
      dataRef.size = size
      self.x, self.y = dataRef.x, dataRef.y
    end
  }):setParent(root)

  local nodeId = node:getId()
  root:setNode(nodeId, {
    x = screenX,
    y = screenY,
    size = size,
    connections = connections or {},
    nodeValue = nodeValue, -- stores the value by the option's key
    selected = selected or false, -- whether the node has been "bought"
  })
  return nodeId
end

--[[
  immutably updates the entire node tree by shallow copying the tree
  and making a copy of the node to be changed
]]
function TreeEditor.setNode(self, nodeId, props)
  if state.editorMode == 'PLAY_READ_ONLY' then
    return
  end

  assert(type(nodeId) == 'string', 'nodeId should be a string')
  assert(props == nil or type(props) == 'table', 'props should be a table')

  local node = self.nodes[nodeId]
  local Object = require 'utils.object-utils'
  local previousState = self.nodes
  self.nodes = Object.clone(self.nodes)
  self.nodes[nodeId] = props and Object.immutableApply(node, props) or nil
  self:onChange(self.nodes, previousState)
end

function TreeEditor.deleteConnection(self, connectionId)
  local connectionIds = F.keys(state.selectedConnection)
  local id1, id2 = unpack(connectionIds)
  local node1, node2 = self.nodes[id1], self.nodes[id2]
  node1.connections[id2] = nil
  node2.connections[id1] = nil
  clearSelections()
end

function TreeEditor.loadFromSerializedState(self)
  local originalEditorMode = self.editorMode
  state.editorMode = 'PLAY'

  for id,props in pairs(rebuildTableBySortingKeys(self.nodes)) do
    placeNode(
      self,
      id,
      -- restore coordinates as pixel units
      props.x * cellSize,
      props.y * cellSize,
      props.connections,
      props.nodeValue,
      props.selected
    )
  end

  state.editorMode = originalEditorMode
end

function TreeEditor.handleInputs(self)
  local root = self

  self.listeners = {
    msgBus.on(msgBus.MOUSE_CLICKED, function(event)
      local mode = self:getMode()
      local _, _, button = unpack(event)

      if ('CLEAR_SELECTIONS' == mode) then
        return clearSelections()
      end

      if ('CONNECTION_CREATE' == mode) then
        local selection = state.selectedNode
        clearSelections()

        -- make connection between nodes
        local shouldAddConnection = not not selection
        if shouldAddConnection then
          local selectedNodeData = root.nodes[selection]
          local hoveredNodeData = root.nodes[state.hoveredNode]

          local lineData = {} -- if more points are added, we define a bezier curve
          self:setNode(state.hoveredNode, {
            connections = Object.immutableApply(
              hoveredNodeData.connections, {
                [selection] = lineData
              }
            )
          })
          self:setNode(selection, {
            connections = Object.immutableApply(
              selectedNodeData.connections, {
                [state.hoveredNode] = lineData
              }
            )
          })
          return
        end
      end

      if ('NODE_CREATE' == mode) and (button == 1) then
        local snapX, snapY = snapToGrid(state.mx - cellSize/2, state.my - cellSize/2)
        placeNode(root, nil, snapX, snapY, nil, nil, nil, cellSize)
      end

      if ('NODE_SELECTION' == mode) and (button == 1) then
        local nodeId = state.hoveredNode
        local node = root.nodes[nodeId]

        if (editorModes.PLAY_UNSELECT_ONLY == state.editorMode) then
          if (node.selected) then
            self:setNode(nodeId, {
              selected = false
            })
          end
        elseif (editorModes.PLAY == state.editorMode) then
          if ((not node.selected) and (not playMode.isNodeSelectable(node, self.nodes, self.nodeValueOptions))) or
            (node.selected and (not playMode.isNodeUnselectable(node, self.nodes)))
          then
            return
          end
          self:setNode(nodeId, {
            selected = not node.selected
          })
          return
        end

        local alreadySelected = state.selectedNode == nodeId
        if alreadySelected then
          state.selectedNode = nil
        else
          state.selectedNode = nodeId
        end
      end

      if ('CONNECTION_SELECTION' == mode) and (button == 1) then
        clearSelections()
        state.selectedConnection = state.hoveredConnection
      end
    end),

    msgBus.on(msgBus.MOUSE_DRAG, function(event)
      if 'NODE_MOVE' == self:getMode() then
        state.movingNode = state.movingNode or state.hoveredNode
        local nodeData = self.nodes[state.movingNode]
        local x, y = snapToGrid(state.mx - nodeData.size/2, state.my - nodeData.size/2)
        self:setNode(state.movingNode, {
          x = x,
          y = y
        })
        clearSelections()
      end

      if 'TREE_PANNING' == self:getMode() then
        local tx = state.translate
        tx.startX = event.startX
        tx.startY = event.startY
        local snapX, snapY = snapToGrid(event.dx, event.dy)
        tx.dx = snapX
        tx.dy = snapY
      end
    end),

    msgBus.on(msgBus.MOUSE_DRAG_END, function(event)
      state.movingNode = nil

      -- update tree translation
      local tx = state.translate
      tx.dxTotal = tx.dxTotal + tx.dx
      tx.dyTotal = tx.dyTotal + tx.dy
      tx.startX = 0
      tx.startY = 0
      tx.dx = 0
      tx.dy = 0
    end),

    msgBus.on(msgBus.KEY_PRESSED, function(event)
      if (event.key == 'escape') then
        clearSelections()
      end

      local serializeTree = 's' == event.key and
        (inputState.keyboard.keysPressed.lctrl or inputState.keyboard.keysPressed.rctrl)
      if serializeTree then
        self:serialize()
      end

      if 'delete' == event.key then
        if state.selectedConnection then
          root:deleteConnection(state.selectedConnection)
        end

        -- delete node
        if state.selectedNode then
          -- remove connections
          local nodeData = root.nodes[state.selectedNode]
          for toNodeId in pairs(nodeData.connections) do
            local toNodeData = root.nodes[toNodeId]
            toNodeData.connections[state.selectedNode] = nil
          end

          -- remove node from list
          self:setNode(state.selectedNode, nil)
          clearSelections()
        end
      end
    end)
  }
end

local function loadState(pathToSave)
    local io = require 'io'
    local savedState = nil
    for line in io.lines(pathToSave) do
      savedState = (savedState or '')..line
    end

    -- IMPORTANT: In lua, key insertion order affects the order of serialization. So we should sort the keys to make sure it is deterministic.
    return (
      savedState and loadstring(savedState)() or {}
    )
  end

function TreeEditor.init(self)
  -- load default state
  if (not self.nodes) then
    local defaultLayout = love.filesystem.getSourceBaseDirectory()..'/src/scene/skill-tree-editor/layout.lua'
    self.nodes = loadState(defaultLayout)
  end

  self:loadFromSerializedState()

  local tick = require 'utils.tick'
  local previousNodesList = self.nodes
  local function autoSerialize()
    local isDirty = previousNodesList ~= self.nodes
    if isDirty then
      self:serialize()
    end
    previousNodesList = self.nodes
  end
  self.autoSave = tick.recur(autoSerialize, 1/60)

  love.mouse.setCursor()

  Component.addToGroup(self, 'gui')

  self:handleInputs()
end

function TreeEditor.handleConnectionInteractions(self)
  -- handle connection collisions
  state.hoveredConnection = nil
  if (not state.hoveredNode) then
    for nodeId,node in pairs(self.nodes) do
      for connectionNodeId in pairs(node.connections or {}) do
        local connectionNode = self.nodes[connectionNodeId]
        local _, len = mouseCollisionWorld:querySegment(node.x, node.y, connectionNode.x, connectionNode.y)
        if len > 0 then
          state.hoveredConnection = {
            [nodeId] = true,
            [connectionNodeId] = true
          }
        end
      end
    end
  end
end

function TreeEditor.showNodeValueOptionsMenu(self)
  if (not state.selectedNode) then
    if self.nodeValueOptionsMenu then
      self.nodeValueOptionsMenu:delete(true)
      self.nodeValueOptionsMenu = nil
    end
    return
  end

  if self.nodeValueOptionsMenu then
    return
  end

  local function setnodeValue(name, optionKey)
    self:setNode(state.selectedNode, {
      nodeValue = optionKey
    })
    clearSelections()
  end
  self.nodeValueOptionsMenu = self.nodeValueOptionsMenu or nodeValueOptions.create({
    id = 'nodeValueMenu',
    x = 0,
    y = 0,
    options = self.nodeValueOptions,

    -- set the node's data
    onSelect = setnodeValue
  })
end

local backgroundColorByEditorMode = {
  [editorModes.EDIT] = Color.DARK_GRAY,
  [editorModes.PLAY] = Color.DARK_GRAY_BLUE,
  [editorModes.PLAY_READ_ONLY] = Color.DARK_GRAY_BLUE,
  [editorModes.PLAY_UNSELECT_ONLY] = Color.DARK_GRAY_BLUE
}

function TreeEditor.update(self, dt)
  local tx, ty = getTranslate()
  local mOffset = mouseCollisionSize
  state.mx, state.my = love.mouse.getX() - tx, love.mouse.getY() - ty
  mouseCollisionWorld:update(mouseCollisionObject, state.mx - mOffset, state.my - mOffset)

  if editorModes.EDIT == state.editorMode then
    self:showNodeValueOptionsMenu()
    self:handleConnectionInteractions()
  end
  self.mode = self:getMode()
  state.editorMode = self.editorMode or editorModes.EDIT
end

function TreeEditor.drawTreeCenter(self)
  if editorModes.EDIT ~= state.editorMode then
    return
  end
  local tx, ty = getTranslate()
  love.graphics.setColor(1,1,1)
  love.graphics.circle('fill', tx, ty, 10)
end

function TreeEditor.drawTooltip(self)
  if (not state.hoveredNode) then
    return
  end

  local tx, ty = getTranslate()
  local node = self.nodes[state.hoveredNode]
  local dataKey = node.nodeValue
  local optionValue = self.nodeValueOptions[dataKey]
  local tooltipContent = optionValue and optionValue:description() or self.defaultNodeDescription
  local x, y = (node.x + tx)/config.scale, (node.y + ty - 20)/config.scale
  local width, height = GuiText.getTextSize(tooltipContent, debugTextLayer.font)
  local padding = 5
  love.graphics.push()
  love.graphics.scale(config.scale)
    local rectX, rectY, rectW, rectH = x - padding, y - padding, width + padding*2, height + padding
    love.graphics.setColor(0,0,0)
    love.graphics.rectangle('fill', rectX, rectY, rectW, rectH)
    love.graphics.setColor(1,1,1)
    love.graphics.rectangle('line', rectX, rectY, rectW, rectH)
  love.graphics.pop()
  debugTextLayer:add(
    tooltipContent,
    Color.WHITE,
    x,
    y
  )
end

function TreeEditor.draw(self)
  local tx, ty = getTranslate()
  love.graphics.push()
  love.graphics.origin()
  local _editorMode = state.editorMode

  -- create background
  love.graphics.setColor(backgroundColorByEditorMode[_editorMode])
  love.graphics.rectangle(
    'fill',
    0, 0, love.graphics.getWidth(), love.graphics.getHeight()
  )

  self:drawTreeCenter()

  -- draw mouse preview position
  if 'NODE_CREATE' == self.mode then
    love.graphics.setColor(1,1,1,0.5)
    local x, y = snapToGrid(
      love.mouse.getX() - cellSize/2,
      love.mouse.getY() - cellSize/2
    )
    love.graphics.rectangle('line', x, y, cellSize, cellSize)
  end

  local function drawConnection(node, connectionNode)
    love.graphics.setLineStyle('rough')
    love.graphics.line(
      node.x + node.size/2 + tx,
      node.y + node.size/2 + ty,
      connectionNode.x + connectionNode.size/2 + tx,
      connectionNode.y + connectionNode.size/2 + ty
    )
  end

  -- draw connections
  for nodeId,node in pairs(self.nodes) do

    for connectionNodeId in pairs(node.connections or {}) do
      local oLineWidth = love.graphics.getLineWidth()
      local connectionNode = self.nodes[connectionNodeId]

      local isSelectedConnection = state.selectedConnection and
        (state.selectedConnection[connectionNodeId] and state.selectedConnection[nodeId])
      -- line outline
      love.graphics.setLineWidth(8)
      if isSelectedConnection then
        love.graphics.setColor(1,0.2,1)
      elseif playMode.isConnectionToSelectableNode(node, connectionNode) then
        love.graphics.setColor(self.colors.nodeConnection.outer)
      else
        love.graphics.setColor(self.colors.nodeConnection.outerNonSelectable)
      end
      drawConnection(node, connectionNode)

      local isHovered = (editorModes.EDIT == _editorMode) and
        state.hoveredConnection and
        state.hoveredConnection[nodeId] and
        state.hoveredConnection[connectionNodeId]
      local color = isHovered and Color.LIME or self.colors.nodeConnection.inner
      love.graphics.setLineWidth(4)
      love.graphics.setColor(color)
      drawConnection(node, connectionNode)
      love.graphics.setLineWidth(oLineWidth)
    end
  end

  love.graphics.setBlendMode('replace')
  for _,node in pairs(self.nodes) do
    local radius = node.size/2
    local x, y = node.x + node.size/2 + tx, node.y + node.size/2 + ty
    -- cut-out the areas that overlap the connections
    love.graphics.setColor(0,0,0)
    love.graphics.circle('fill', x, y, radius)
  end
  love.graphics.setBlendMode('alpha')

  -- draw nodes
  for nodeId,node in pairs(self.nodes) do
    local dataKey = node.nodeValue
    local optionValue = self.nodeValueOptions[dataKey]
    local radius = node.size/2
    local x, y = node.x + node.size/2 + tx, node.y + node.size/2 + ty

    if (editorModes.PLAY == _editorMode) or
      (editorModes.PLAY_READ_ONLY == _editorMode) or
      (editorModes.PLAY_UNSELECT_ONLY == _editorMode)
    then
      if node.selected then
        love.graphics.setColor(1,1,1)
      else
        love.graphics.setColor(1,1,1,0.3)
      end
      local AnimationFactory = require 'components.animation-factory'
      local sprite = optionValue and optionValue.image or self.defaultNodeImage
      local animation = AnimationFactory:newStaticSprite(sprite)
      local ox, oy = animation:getOffset()
      local scale = 2
      love.graphics.draw(
        AnimationFactory.atlas, animation.sprite,
        x, y,
        0,
        scale, scale,
        ox, oy
      )
    end

    if (editorModes.EDIT == _editorMode) then
      if node.hovered then
        love.graphics.setColor(0,1,0)
      else
        love.graphics.setColor(1,0.5,0)
      end
      love.graphics.circle('fill', x, y, radius)

      if optionValue then
        debugTextLayer:add(
          optionValue.name,
          Color.WHITE,
          x/config.scale, y/config.scale
        )
      end

      if state.selectedNode == nodeId then
        local oLineWidth = love.graphics.getLineWidth()
        love.graphics.setLineWidth(2)
        love.graphics.setColor(1,1,1)
        love.graphics.circle('line', x, y, radius + 4)
        love.graphics.setLineWidth(oLineWidth)
      end
    end

    if self.debug.connectionCount then
      debugTextLayer:add(
        #F.keys(node.connections),
        Color.WHITE,
        x/config.scale, y/config.scale
      )
    end
  end

  self:drawTooltip()

  love.graphics.pop()
end

function TreeEditor.final(self)
  self.autoSave:stop()
  msgBus.off(self.listeners)
end

return Component.createFactory(TreeEditor)