local functional = require 'utils.functional'
local GuiText = require 'components.gui.gui-text'
local font = require 'components.font'
local Vec2 = require 'modules.brinevector'
local propTypes = require 'utils.prop-types'

local columnPropTypes = {
  content = {}, -- love2d text object
  maxWidth = 100, -- content max width
  width = nil, -- if defined, forces the container to the specified width, otherwise defaults to auto-width
  align = 'left',
  height = nil, -- if defined, forces the container to the specified height, otherwise defaults to auto-height
  font = nil, -- love2d font object
  fontSize = 16,
  padding = 0, -- container padding
  background = nil, -- background color
  border = nil,
  borderWidth = 0
}

local rowPropTypes = {
  marginTop = 0,
  marginBottom = 0,
}

return function(columns, rowProps)
  rowProps = propTypes(rowProps or {}, rowPropTypes)
  rowProps.__index = rowProps

  assert(type(columns) == 'table', 'row function must be an array of columns')
  if #columns > 0 then
    assert(type(columns[1]) == 'table', 'a row must be a list of column objects')
  end

  local rowHeight = 0 -- highest column height
  local rowWidth = 0 -- total width of all columns
  local parsedColumns = functional.map(columns, function(col)
    col = propTypes(col, columnPropTypes)
    col.__index = col
    local widthAdjustment = (col.padding * 2) + (col.borderWidth * 2)
    local textMaxWidth = (col.width or col.maxWidth) - widthAdjustment
    local textW, textH = GuiText.getTextSize(col.content, col.font, textMaxWidth)
    local contentWidth = col.width and (col.width - widthAdjustment) or (textW + widthAdjustment)
    local heightAdjustment = math.max(0, (col.font:getLineHeight() - 0.8) * col.font:getHeight())
    local actualHeight = textH + (col.padding * 2) + (col.borderWidth * 2) - heightAdjustment
    local actualWidth = col.width or contentWidth
    rowHeight = math.max(rowHeight, actualHeight)
    rowWidth = rowWidth + actualWidth
    return setmetatable({
      height = actualHeight,
      contentHeight = textH,
      width = actualWidth,
      contentWidth = contentWidth
    }, col)
  end)

  return setmetatable({
    height = rowHeight,
    width = rowWidth,
    columns = parsedColumns
  }, rowProps)
end