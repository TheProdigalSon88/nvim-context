---@meta

---@class Context
---@field setup fun(opts: Ctx.Options): nil

---@class Context.Options
---@field repo Context.Options.Repo
---@field personal Context.Options.Personal

---@class Context.Options.Repo
---@field dir_name string
---@field enable boolean

---@class Context.Options.Personal
---@field dir_name string
---@field enable boolean

---@class Context.Config
---@field defaults Context.Options: Default options
---@field options Context.Options: User options
---@field setup fun(opts: Context.Options): nil Extend the defaults options table with the user options
