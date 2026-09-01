---@class ContextListItem
---@field id string
---@field title string

---@class ContextList
---@field id? number
---@field title? string
---@field description? string
---@field items? ContextItem[]
---@field git_hash? string
---@field timestamp string|osdate

---@class ContextItem
---@field id? number
---@field list_id? number
---@field list_title? string
---@field filename? string
---@field lnum? number
---@field end_lnum? number
---@field col? number
---@field labels? string[]
---@field description? string
---@field base_text? string
---@field display_text? string
---@field git_hash? string
---@field timestamp string

---@class UpdateContextItem
---@field id? number
---@field title? string
---@field description? string
---@field git_hash? string
---@field timestamp string|osdate

---@class UserData
---@field id? number
---@field description string
---@field base_text string
---@field display_text string
---@field git_hash string|nil
---@field timestamp string|osdate

---@class ReferenceBuffer
---@field default string
---@field code? string
---@field source_buf? number
---@field readonly? boolean
---@field diagram_keymap? string               keymap to insert a bare mermaid fenced block, e.g. "<leader>m"; nil disables
---@field diagram_enabled? boolean             auto-render diagrams on open when true
---@field diagram_snippets? table<string,string>  map of keymap string -> diagram type for typed snippet insertion
