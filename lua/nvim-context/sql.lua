local sqlite = require("sqlite")
local julianday, strftime = sqlite.lib.julianday, sqlite.lib.strftime

---@alias ContextType '"general"' | '"flow"'

---@class wiki
---@field id string: unique ID
---@field title string
---@field labels string[]
---@field tags string[]
---@field content string
---@field created string
---@field updated string
---@field last_git_commit string

---@class ContextEntry
---@field id string: unique ID
---@field title string
---@field description string
---@field wiki string
---@field type ContextType
