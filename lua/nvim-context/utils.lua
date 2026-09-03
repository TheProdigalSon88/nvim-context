local Utils = {}

---@param context vim.fn.setqflist.what
---@param previous_context ContextList|nil
---@return boolean,ContextList
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

         if not user_data.id then
            table.insert(new_items, {
               filename = Utils.normalize_qf_path(item, root),
               bufnr = item.bufnr,
               lnum = item.lnum,
               end_lnum = item.end_lnum,
               col = 1,
               text = user_data.display_text,
               description = user_data.description,
               base_text = user_data.base_text,
               display_text = user_data.display_text,
               git_hash = Utils.git_hash(),
               timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
            })
         else
            -- Existing item: compare description and range against previous
            local prev = prev_by_id[user_data.id]
            if prev then
               local new_item = {
                  id = user_data.id,
                  git_hash = Utils.git_hash(),
                  timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
               }

               if user_data.description ~= prev.description then
                  new_item.description = user_data.description
               end
               if item.lnum ~= prev.lnum then
                  new_item.lnum = item.lnum
               end
               if item.end_lnum ~= prev.end_lnum then
                  new_item.end_lnum = item.end_lnum
               end
               if user_data.base_text ~= prev.base_text then
                  new_item.base_text = user_data.base_text
               end
               if user_data.display_text ~= prev.display_text then
                  new_item.display_text = user_data.display_text
               end
               table.insert(updated_items, new_item)
            end
         end
      end
   else
      for _, item in ipairs(items) do
         local user_data = type(item.user_data) == "table" and item.user_data or {}
         table.insert(new_items, {
            filename = Utils.normalize_qf_path(item, root),
            bufnr = item.bufnr,
            lnum = item.lnum,
            end_lnum = item.end_lnum,
            col = 1,
            text = user_data.display_text,
            description = user_data.description,
            base_text = user_data.base_text,
            display_text = user_data.display_text,
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

---@param path string
---@param root string
---@return string
local function relativize(path, root)
   path = vim.fn.fnamemodify(path, ":p")
   if root and path:sub(1, #root + 1) == root .. "/" then
      return path:sub(#root + 2)
   end
   return vim.fn.fnamemodify(path, ":~")
end

---@param bufnr number
---@param root string
function Utils.get_file_path(bufnr, root)
   return relativize(vim.api.nvim_buf_get_name(bufnr), root)
end

---@param item vim.quickfix.entry
---@return string|nil
function Utils.qf_abspath(item)
   if item.bufnr and item.bufnr > 0 and vim.api.nvim_buf_is_valid(item.bufnr) then
      local name = vim.api.nvim_buf_get_name(item.bufnr)
      if name ~= "" then
         return vim.fn.fnamemodify(name, ":p")
      end
   end
   if item.filename and item.filename ~= "" then
      return vim.fn.fnamemodify(item.filename, ":p")
   end
   return nil
end

---@param item vim.quickfix.entry
---@param root string
---@return string|nil
function Utils.normalize_qf_path(item, root)
   local abs = Utils.qf_abspath(item)
   if not abs then
      return nil
   end
   return relativize(abs, root)
end

---@param item vim.quickfix.entry
---@return number, number
function Utils.qf_range(item)
   local start_line = (item.lnum and item.lnum > 0) and item.lnum or 1
   local end_line = (item.end_lnum and item.end_lnum > 0) and item.end_lnum or start_line
   if end_line < start_line then
      end_line = start_line
   end
   return start_line, end_line
end

---@param item vim.quickfix.entry
---@param start_line number
---@param end_line number
---@return string[]
function Utils.read_qf_source(item, start_line, end_line)
   if
      item.bufnr
      and item.bufnr > 0
      and vim.api.nvim_buf_is_valid(item.bufnr)
      and vim.api.nvim_buf_is_loaded(item.bufnr)
   then
      return vim.api.nvim_buf_get_lines(item.bufnr, start_line - 1, end_line, false)
   end
   local abs = Utils.qf_abspath(item)
   if not abs or vim.fn.filereadable(abs) == 0 then
      return {}
   end
   local lines = vim.fn.readfile(abs, "", end_line)
   if type(lines) ~= "table" then
      return {}
   end
   return vim.list_slice(lines, start_line, end_line)
end

---@param lines string[]
---@return string, string
function Utils.lines_to_display_and_base(lines)
   local first_line = lines[1] or ""
   local display_text = first_line
   if #lines > 1 then
      display_text = string.format("%s (+%d more lines)", first_line, #lines - 1)
   end
   return display_text, table.concat(lines, "\n")
end

---@param item vim.quickfix.entry
---@param root string
---@param git_hash? string|nil
---@param timestamp? string|osdate
---@return vim.quickfix.entry|nil
function Utils.qfitem_to_context_item(item, root, git_hash, timestamp)
   if not item or item.valid == 0 then
      return nil
   end
   if type(item.user_data) == "table" and item.user_data.base_text ~= nil then
      return item
   end

   local start_line, end_line = Utils.qf_range(item)
   local abs = Utils.qf_abspath(item)
   local lines = Utils.read_qf_source(item, start_line, end_line)
   local qf_text = item.text or ""
   local display_text, base_text = Utils.lines_to_display_and_base(lines)

   if #lines == 0 and qf_text ~= "" then
      display_text = qf_text
      base_text = qf_text
   end

   if (not abs or abs == "") and base_text == "" then
      return nil
   end

   local first_line = lines[1] or ""
   local description = (qf_text ~= "" and qf_text ~= first_line) and qf_text or ""

   ---@type vim.quickfix.entry
   return {
      filename = abs,
      bufnr = item.bufnr,
      lnum = start_line,
      end_lnum = end_line,
      col = (item.col and item.col > 0) and item.col or 1,
      text = display_text,
      ---@type UserData
      user_data = {
         id = nil,
         description = description,
         base_text = base_text,
         display_text = display_text,
         git_hash = git_hash or Utils.git_hash(),
         timestamp = timestamp or os.date("!%Y-%m-%dT%H:%M:%SZ"),
      },
   }
end

---@param items vim.quickfix.entry[]
---@param root string
---@return vim.quickfix.entry[], number
function Utils.qflist_to_context_items(items, root)
   local converted = {}
   local skipped = 0
   local git_hash = Utils.git_hash()
   local timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
   for _, item in ipairs(items or {}) do
      local ctx_item = Utils.qfitem_to_context_item(item, root, git_hash, timestamp)
      if ctx_item then
         table.insert(converted, ctx_item)
      else
         skipped = skipped + 1
      end
   end
   return converted, skipped
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

   local selected_lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
   local display_text, base_text = Utils.lines_to_display_and_base(selected_lines)

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
