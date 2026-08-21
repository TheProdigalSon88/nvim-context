local M = {}
local Caching = require("nvim-context.caching")

-- One sqlite db handle per git root path.
local db_cache = {}

local NULL = setmetatable({}, {
   __tostring = function()
      return "NULL"
   end,
})
M.NULL = NULL

---Return (and lazily create) the sqlite db for the given git root.
---The database lives at <root>/.nvim-context/context.db and is created with
---the full schema on first access.
---@param root string  absolute path to the git repository root
---@return table|nil
local function get_db(root)
   if db_cache[root] then
      return db_cache[root]
   end

   local sqlite = require("sqlite")

   local dir = root .. "/.nvim-context"
   if vim.fn.isdirectory(dir) == 0 then
      vim.fn.mkdir(dir, "p")
   end

   local dbpath = dir .. "/context.db"

   local d = sqlite:extend({
      uri = dbpath,
      lists = {
         id = { type = "integer", primary = true },
         root = { type = "text", required = true },
         title = { type = "text", required = true },
         description = "text",
      },
      items = {
         id = { type = "integer", primary = true },
         list_id = { type = "integer", required = true, reference = "lists.id", on_delete = "cascade" },
         filename = { type = "text", required = true },
         lnum = "integer",
         end_lnum = "integer",
         col = "integer",
         description = "text",
         base_text = "text",
         display_text = "text",
         git_hash = "text",
         timestamp = "text",
      },
   })
   d:open()

   -- sqlite.lua's schema DSL does not support multi-column UNIQUE constraints,
   -- so enforce UNIQUE(root, title) on lists via a raw one-shot statement.
   pcall(function()
      d:eval("CREATE UNIQUE INDEX IF NOT EXISTS idx_lists_root_title ON lists(root, title)")
   end)

   pcall(function()
      d:eval("CREATE INDEX IF NOT EXISTS idx_items_file_lnum ON items(filename, lnum, end_lnum)")
   end)

   db_cache[root] = d
   return d
end

---@param root string
---@return ContextListItem[]
function M.list_titles(root)
   return Caching.get_or_set("titles:" .. root, function()
      local d = get_db(root)
      if not d then
         error("nvim-context: database unavailable")
      end

      local rows = d:eval("SELECT id, title FROM lists WHERE root = ? ORDER BY title", root)
      if type(rows) ~= "table" then
         return {}
      end

      local titles = {}
      for _, row in ipairs(rows) do
         table.insert(titles, { title = row.title, id = row.id })
      end
      return titles
   end)
end

---@param root string
---@param list_id integer
---@param items ContextItem[]
local function insert_items(root, list_id, items)
   local d = get_db(root)
   -- Use d:eval() with explicit named bind parameters instead of the high-level
   -- d.items:insert() API. sqlite.lua's parser.lua pvalues() heuristic detects
   -- strings that look like function calls (matching ^[%S]+%(.*%)$) and splices
   -- them raw into the SQL VALUES clause rather than binding them safely. Any
   -- base_text or display_text containing Lua/code snippets like `foo(...)` will
   -- match that pattern and cause an SQL syntax error. d:eval() bypasses the
   -- heuristic entirely and always uses proper named parameter binding.
   for _, item in ipairs(items or {}) do
      d:eval([[
         INSERT INTO items
            (list_id, filename, lnum, end_lnum, col, description,
             base_text, display_text, git_hash, timestamp)
         VALUES
            (:list_id, :filename, :lnum, :end_lnum, :col, :description,
             :base_text, :display_text, :git_hash, :timestamp)
      ]], {
         list_id      = list_id,
         filename     = item.filename,
         lnum         = item.lnum,
         end_lnum     = item.end_lnum,
         col          = item.col,
         description  = item.description,
         base_text    = item.base_text,
         display_text = item.display_text,
         git_hash     = item.git_hash,
         timestamp    = item.timestamp,
      })
   end
end

---@param root string
---@param items UpdateContextItem[]
local function update_items(root, items)
   local d = get_db(root)
   for _, item in ipairs(items or {}) do
      local set = {}

      if item.description ~= nil then
         set.description = item.description
      end
      if item.git_hash ~= nil then
         set.git_hash = item.git_hash
      end
      if item.timestamp ~= nil then
         set.timestamp = item.timestamp
      end

      if next(set) ~= nil then
         d.items:update({ where = { id = item.id }, set = set })
      end
   end
end

---@param root string
---@param data Context
---@param items ContextItem[]
---@return integer list_id
function M.insert_context(root, data, items)
   local d = get_db(root)
   if not d then
      error("nvim-context: database unavailable")
   end

   local list_id = d.lists:insert({
      root = root,
      title = data.title,
      description = data.description or "",
   })

   insert_items(root, list_id, items)
   Caching.invalidate("titles:" .. root)
   Caching.invalidate("Context:" .. root .. ":" .. data.title)
   return list_id
end

---@param root string
---@param updated_context Context
---@param new_items ContextItem[]
---@param updated_items UpdateContextItem[]
---@param title string
function M.update_context(root, updated_context, new_items, updated_items, title)
   local d = get_db(root)
   if not d then
      error("nvim-context: database unavailable")
   end

   local existing = d.lists:get({ where = { id = updated_context.id } })
   if not existing or not existing[1] then
      error("no saved list found with id: " .. tostring(updated_context.id))
   end
   local list_id = existing[1].id

   local set = {}
   if updated_context.title ~= nil then
      set.title = updated_context.title
   end
   if updated_context.description ~= nil then
      set.description = updated_context.description or ""
   end

   if next(set) ~= nil then
      d.lists:update({ where = { id = list_id }, set = set })
   end

   insert_items(root, list_id, new_items)
   update_items(root, updated_items)
   Caching.invalidate("titles:" .. root)
   Caching.invalidate("Context:" .. root .. ":" .. title)
end

---@param root string
---@param id number
---@return Context|nil
function M.load_list(root, id)
   if not id then
      return nil
   end

   local d = get_db(root)
   if not d then
      error("nvim-context: database unavailable")
   end

   local cache_key = "Context:" .. root .. ":" .. id
   return Caching.get_or_set(cache_key, function()
      local lists = d.lists:get({ where = { id = id } })
      local list = lists and lists[1]
      if not list then
         return nil
      end

      local rows = d.items:get({ where = { list_id = list.id } })

      ---@type ContextItem[]
      local items = {}
      for _, row in ipairs(rows or {}) do
         table.insert(items, {
            id = row.id,
            filename = row.filename,
            lnum = row.lnum,
            end_lnum = row.end_lnum,
            col = row.col,
            description = row.description,
            base_text = row.base_text,
            display_text = row.display_text,
            git_hash = row.git_hash,
            timestamp = row.timestamp,
         })
      end

      return {
         id = list.id,
         title = list.title,
         description = list.description,
         items = items,
      }
   end)
end

---@param root string
---@param filename string  root-relative path, exact match
---@param lnum integer
---@param end_lnum integer?  when provided, matches rows whose range overlaps [lnum, end_lnum]
---@return ContextItem[]
function M.get_items_at_line(root, filename, lnum, end_lnum)
   local d = get_db(root)
   if not d then
      error("nvim-context: database unavailable")
   end

   local rows
   local query =
      "SELECT items.*, lists.title AS list_title FROM items JOIN lists ON lists.id = items.list_id WHERE items.filename = ? AND items.lnum <= ? AND items.end_lnum >= ?"
   if end_lnum then
      rows = d:eval(query, { filename, end_lnum, lnum })
   else
      rows = d:eval(query, { filename, lnum, lnum })
   end
   if type(rows) ~= "table" then
      return {}
   end

   ---@type ContextItem[]
   local items = {}
   for _, row in ipairs(rows) do
      table.insert(items, {
         id = row.id,
         list_id = row.list_id,
         list_title = row.list_title,
         filename = row.filename,
         lnum = row.lnum,
         end_lnum = row.end_lnum,
         col = row.col,
         description = row.description,
         base_text = row.base_text,
         display_text = row.display_text,
         git_hash = row.git_hash,
         timestamp = row.timestamp,
      })
   end
   return items
end

return M
