local M = {}

local defaults = {
  option = "default",
}

M.options = vim.deepcopy(defaults)

M.set = function(opts)
  M.options = vim.tbl_deep_extend("force", M.options, opts or {})
end

M.get = function()
  return M.options
end

return M
