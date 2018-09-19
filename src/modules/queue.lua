local perf = require 'utils.perf'
local typeCheck = require 'utils.type-check'
local noop = require 'utils.noop'
local assign = require 'utils.object-utils'.assign

local Q = {}

local defaultOptions = {
  development = false,
}

function Q:new(options)
  options = assign({}, defaultOptions, options)
  local queue = {
    list = nil,
    length = 0, -- num of calls added to the queue
    minOrder = 0,
    maxOrder = 0, -- highest order that has been added to the queue
    development = options.development,
    beforeFlush = noop,
    ready = true
  }
  setmetatable(queue, self)
  self.__index = self
  return queue
end

local orderError = function(order)
  local valid = type(order) == 'number'
    and order > 0
    and order % 1 == 0 -- must be integer
  if valid then return true end
  return false, 'order must be greater than 0 and an integer, received `'..tostring(order)..'`'
end
local max, min = math.max, math.min

-- insert callback with maximum 2 arguments
function Q:add(order, cb, a, b)
  local isNewQueue = not self.list
  if isNewQueue then
    self.list = {}
    self.minOrder = order
    self.maxOrder = order
  end

  if self.development then
    typeCheck.validate(
      order,
      orderError
    )
  end

  local list = self.list[order]
  if not list then
    list = {}
    self.list[order] = list
  end

  local itemIndex = self.length + 1
  local item = {cb, a, b}

  list[#list + 1] = item
  self.length = self.length + 1
  self.minOrder = min(self.minOrder, order)
  self.maxOrder = max(self.maxOrder, order)
  return self
end

-- iterate callbacks by `order` and clears the queue
local emptyList = {}
function Q:flush()
  self:beforeFlush()
  local list = self.list or emptyList
  self.list = nil
  local _start, _end = self.minOrder, self.maxOrder
  for i=_start, _end do
    local row = list[i]
    local rowLen = row and #row or 0
    for j=1, rowLen do
      local item = row[j]
      item[1](item[2], item[3])
    end
  end
  self.length = 0
  return self
end

function Q:onBeforeFlush(fn)
  self.beforeFlush = fn
end

function Q:getStats()
  return self.minOrder, self.maxOrder, self.length
end

return Q