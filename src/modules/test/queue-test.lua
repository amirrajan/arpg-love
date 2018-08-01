local Q = require 'modules.queue'

local queue = Q:new()

local calls = {}
queue:add(2, function()
  table.insert(calls, 2)
end)

assert(
  queue.minOrder == 2 and queue.maxOrder == 2,
  'min and max order should be same since its the first item'
)

queue:add(1, function()
  table.insert(calls, 1)
end)

queue:flush()

assert(#calls == 2, 'should be equal to number of items in queue')
assert(
  calls[1] == 1
  and calls[2] == 2,

  'should be called based on `order` value'
)

assert(queue.length == 0, 'queue should be empty')


-- local perf = require 'utils.perf'
-- local bench = perf({
--   done = function (timeTaken)
--     print('queue', timeTaken)
--   end
-- })(function ()
--   local random = math.random
--   local function callback()
--     return random(0, 9999)
--   end
--   for i=1, 5000 do
--     queue:add(random(1, 1000), callback)
--   end
--   queue:flush()
-- end)

-- for i=1, 100 do
--   bench()
-- end