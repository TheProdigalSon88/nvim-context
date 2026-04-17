local M = {}

---@type Context.Options
M.defaults = {
  repo = {
    dir_name = ".context-repo",
    enable = false
  },
  personal = {
    dir_name = ".context-repo",
    enable = false
  }
}

---@type Context.Options
---@diagnostic disable-next-line: missing-fields
M.options = {}

---Extend the defaults options table with the user options
---@param opts Ctx.Options Plugin options
M.setup = function(opts)
  M.options = vim.tbl_deep_extend("force", {}, M.defaults, opts or {})
end

---@type Context.Config
return M
