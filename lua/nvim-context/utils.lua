local Utils = {}

---@param context vim.fn.setqflist.what
---@param previous_context Context|nil
---@return boolean,Context
function Utils.qflist_to_context(context, previous_context)
   local ctx = type(context.context) == "table" and context.context or {}
   local result = {}
   local new = true
   if previous_context then
      result.id = previous_context.id
      if previous_context.description ~= ctx.description then
         result.description = ctx.description
      end
      if previous_context.title ~= context.title then
         result.title = context.title
      end
      new = false
   else
      result.description = ctx.description
      result.title = context.title
   end
   return new, result
end

---@param items vim.quickfix.entry[]
---@param previous_items ContextItem[]|nil
---@param root string
---@return ContextItem[],UpdateContextItem[]
function Utils.qfitems_to_dbrows(items, previous_items, root)
   ---@type ContextItem[]
   local new_items = {}
   ---@type ContextItem[]
   local updated_items = {}

   if previous_items then
      local prev_by_id = {}
      for _, prev in ipairs(previous_items) do
         if prev.id then
            prev_by_id[prev.id] = prev
         end
      end

      for _, item in ipairs(items) do
         local user_data = type(item.user_data) == "table" and item.user_data or {}

         if not item.user_data.id then
            table.insert(new_items, {
               filename = Utils.get_file_path(item.bufnr, root),
               bufnr = item.bufnr,
               lnum = item.lnum,
               end_lnum = item.end_lnum,
               col = 1,
               text = item.user_data.display_text,
               description = item.user_data.description,
               base_text = item.user_data.base_text,
               display_text = item.user_data.display_text,
               git_hash = Utils.git_hash(),
               timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
            })
         else
            -- Existing item: compare labels and description against previous
            local prev = prev_by_id[item.user_data.id]
            if prev then
               local description = user_data.description
               local description_changed = description ~= prev.description
               local new_item = {
                  id = item.user_data.id,
                  git_hash = Utils.git_hash(),
                  timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
               }

               if description_changed then
                  new_item.description = description
               end
               table.insert(updated_items, new_item)
            end
         end
      end
   else
      for _, item in ipairs(items) do
         table.insert(new_items, {
            filename = Utils.get_file_path(item.bufnr, root),
            bufnr = item.bufnr,
            lnum = item.lnum,
            end_lnum = item.end_lnum,
            col = 1,
            text = item.user_data.display_text,
            description = item.user_data.description,
            base_text = item.user_data.base_text,
            display_text = item.user_data.display_text,
            git_hash = Utils.git_hash(),
            timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
         })
      end
   end

   return new_items, updated_items
end

---@param rows ContextItem[]
---@param root string
---@return vim.quickfix.entry[]
function Utils.dbrows_to_qfitems(rows, root)
   ---@type vim.quickfix.entry[]
   local items = {}
   for _, row in ipairs(rows) do
      ---@type vim.quickfix.entry
      local item = {
         id = row.id,
         filename = vim.fn.expand(root .. "/" .. row.filename),
         lnum = row.lnum,
         end_lnum = row.end_lnum,
         col = row.col,
         text = row.display_text,
         ---@type UserData
         user_data = {
            id = row.id,
            description = row.description,
            base_text = row.base_text,
            display_text = row.display_text,
            git_hash = row.git_hash,
            timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
         },
      }
      table.insert(items, item)
   end
   return items
end

---@param bufnr number
---@param root string
function Utils.get_file_path(bufnr, root)
   local filename = vim.api.nvim_buf_get_name(bufnr)
   filename = vim.fn.fnamemodify(filename, ":p")
   if root and filename:sub(1, #root + 1) == root .. "/" then
      return filename:sub(#root + 2)
   end
   return vim.fn.fnamemodify(filename, ":~")
end

---@return string|nil
function Utils.git_hash()
   local root = vim.fs.root(0, ".git")
   if not root then
      return nil
   end
   local hash = vim.fn.system({ "git", "-C", root, "rev-parse", "--short", "HEAD" }):gsub("%s+$", "")
   if vim.v.shell_error ~= 0 or hash == "" then
      vim.notify("Nvim-context :" .. vim.v.shell_error, vim.log.levels.ERROR)
      return nil
   end
   return hash
end

---@param bufnr number
---@return string, string, number, number
function Utils.getLines(bufnr)
   local start_line, end_line
   local mode = vim.fn.mode()
   if mode:match("[vV\22]") then
      local s = vim.fn.getpos("v")
      local e = vim.fn.getpos(".")
      start_line = math.min(s[2], e[2])
      end_line = math.max(s[2], e[2])
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
   else
      start_line = vim.fn.line(".")
      end_line = start_line
   end

   local first_line = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, start_line, false)[1] or ""
   local display_text = first_line
   if end_line > start_line then
      display_text = string.format("%s (+%d more lines)", first_line, end_line - start_line)
   end

   local selected_lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
   local base_text = table.concat(selected_lines, "\n")

   return display_text, base_text, start_line, end_line
end

---@param qflist vim.quickfix.entry[]
---@param item vim.quickfix.entry
---@return number|nil
function Utils.find_qf_index(qflist, item)
   local id = type(item.user_data) == "table" and item.user_data.id
   if id then
      for i, entry in ipairs(qflist) do
         if type(entry.user_data) == "table" and entry.user_data.id == id then
            return i
         end
      end
   end
   local ts = type(item.user_data) == "table" and item.user_data.timestamp
   for i, entry in ipairs(qflist) do
      local ud = type(entry.user_data) == "table" and entry.user_data
      if ud and entry.lnum == item.lnum and entry.end_lnum == item.end_lnum and ud.timestamp == ts then
         return i
      end
   end
   return nil
end

---@param items vim.quickfix.entry[]
---@param previous_items ContextItem[]|nil
---@return number[]
function Utils.deleted_item_ids(items, previous_items)
   if not previous_items or #previous_items == 0 then
      return {}
   end

   local current_ids = {}
   for _, item in ipairs(items or {}) do
      local id = type(item.user_data) == "table" and item.user_data.id
      if id then
         current_ids[id] = true
      end
   end

   local deleted = {}
   for _, prev in ipairs(previous_items) do
      if prev.id and not current_ids[prev.id] then
         table.insert(deleted, prev.id)
      end
   end
   return deleted
end

return Utils
