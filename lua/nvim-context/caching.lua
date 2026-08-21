local Caching = {}
local cache = {}

---@param key string
---@param fn fun(): any
---@return any
function Caching.get_or_set(key, fn)
   if cache[key] ~= nil then
      return cache[key]
   end
   cache[key] = fn()
   return cache[key]
end

---@param key string
function Caching.invalidate(key)
   cache[key] = nil
end

return Caching
