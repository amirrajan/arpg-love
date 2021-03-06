local setProp = require 'utils.set-prop'

-- test with debug mode
local objWithDebug = setProp({
  foo = 'foo'
})

assert(
  objWithDebug:set('foo', 1).foo == 1,
  'value was not properly set'
)

local errorFree, retValue = pcall(function()
  return objWithDebug:set('bar', 1)
end)

-- test without debug mode
local obj = setProp({
  foo = 'foo'
})
assert(obj:set('foo', 1).foo == 1, 'value was not properly set')
local errorFree, retValue = pcall(function()
  return obj:set('bar', 1)
end)
assert(errorFree, 'an error should not be thrown')