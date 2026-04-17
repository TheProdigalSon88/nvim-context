local M = {}

M.setup = function(opts)
  vim.validate({
    option = { opts.option, { "string", "nil" } },
  })

  local config = vim.tbl_deep_extend("force", {
    option = "default",
  }, opts or {})

  require("nvim-context.config").set(config)
end

M.some_function = function()
  return require("nvim-context.config").get().option
end

return M
