local L = {}
local logtag = "NVIM-CONTEXT :"

---@param msg string
function L.error(msg)
   vim.notify(logtag .. msg, vim.log.levels.ERROR)
end

---@param msg string
function L.info(msg)
   vim.notify(logtag .. msg, vim.log.levels.INFO)
end

---@param msg string
function L.debug(msg)
   vim.notify(logtag .. msg, vim.log.levels.DEBUG)
end

return L
