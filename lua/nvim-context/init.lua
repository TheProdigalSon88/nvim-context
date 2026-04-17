local M = {}

---@param opts Context.Options
M.setup = function(opts)
  require("nvim-context").setup(opts)
end

---@type Context
return M
