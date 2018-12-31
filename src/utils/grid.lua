-- 2-d grid utilities

local Grid = {}

Grid.clone = require 'utils.clone-grid'

function Grid.get(grid, x, y)
  local row = grid[y]
  return row and row[x]
end

function Grid.set(grid, x, y, value)
  local row = grid[y]
  if (not row) then
    row = {}
    grid[y] = row
  end
  row[x] = value
  return value
end

function Grid.forEach(grid, callback)
  for y,row in pairs(grid) do
    for x,colValue in pairs(row) do
      callback(colValue, x, y)
    end
  end
end

local neighborOffsets = {
  {-1, -1},
  {0, -1},
  {1, 1},
  {-1, 0},
  {1, 0},
  {-1, 1},
  {0, 1},
  {1, 1},
}

local cardinalNeighborOffsets = {
  neighborOffsets[2],
  neighborOffsets[4],
  neighborOffsets[5],
  neighborOffsets[7],
}

-- traverses around the neighboring cells around a cell
function Grid.walkNeighbors(grid, x, y, callback, seed, cardinalOnly)
  local offsets = cardinalOnly and cardinalNeighborOffsets or neighborOffsets
  for i=1, #offsets do
    local o = offsets[i]
    local xOffset, yOffset = o[1], o[2]
    local trueX, trueY = x + xOffset, y + yOffset
    local v = Grid.get(grid, trueX, trueY)
    seed = callback(seed, v)
  end
  return seed
end

function Grid.getIndexByCoordinate(grid, x, y)
  local numCols = #grid[1]
  return (y * numCols) + x
end

local floor = math.floor
function Grid.getCoordinateByIndex(grid, index)
  local numCols = #grid[1]
  local y = floor(index / numCols)
  local x = index - (y * numCols)
  return x, y
end

return Grid