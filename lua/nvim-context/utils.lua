local Utils = {}
local Context = require("nvim-context")
local log = require("nvim-context.log")
local sql = require("nvim-context.sql")

--DONE
---@param context vim.fn.setqflist.what
---@param previous_context ContextList|nil
---@return boolean,ContextList
function Utils.qflist_to_context(context, previous_context)
   local ctx = type(context.context) == "table" and context.context or {}
   local result = {}
   local new = true
   local ctx_type = ctx.type or "context"
   if previous_context then
      result.id = previous_context.id
      if previous_context.description ~= ctx.description then
         result.description = ctx.description
      end
      if previous_context.title ~= context.title then
         result.title = context.title
      end
      if (previous_context.type or "context") ~= ctx_type then
         result.type = ctx_type
      end
      if ctx.flows ~= nil then
         result.flows = ctx.flows
      end
      new = false
   else
      result.description = ctx.description
      result.title = context.title
      result.type = ctx_type
      result.flows = ctx.flows
   end
   return new, result
end

--DONE
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

--DONE
---@param item vim.quickfix.entry
---@param root string
---@return string|nil
local function normalize_qf_path(item, root)
   local abs = Utils.qf_abspath(item)
   if not abs then
      return nil
   end
   return relativize(abs, root)
end

--DONE
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
               filename = normalize_qf_path(item, root),
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
            filename = normalize_qf_path(item, root),
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

--DONE
---@param rows ContextItem[]
---@param root string
---@return vim.quickfix.entry[]
local function dbrows_to_qfitems(rows, root)
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



--DONE
---@param bufnr number
---@param root string
function Utils.get_file_path(bufnr, root)
   return relativize(vim.api.nvim_buf_get_name(bufnr), root)
end

--DONE
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



--DONE
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

--DONE
---@param item vim.quickfix.entry|nil
---@return boolean
function Utils.is_context_item(item)
   return type(item) == "table"
      and type(item.user_data) == "table"
      and type(item.user_data.git_hash) == "string"
      and item.user_data.git_hash ~= ""
end

--DONE
---@param item vim.quickfix.entry
---@return string|nil
function Utils.git_root_for_item(item)
   local abs = Utils.qf_abspath(item)
   if abs and abs ~= "" then
      return vim.fs.root(abs, ".git")
   end
   return vim.fs.root(0, ".git")
end

--DONE
---@param item vim.quickfix.entry
---@param start_line number
---@param end_line number
---@return string[]
local function read_qf_source(item, start_line, end_line)
   if
      item.bufnr
      and item.bufnr > 0
      and vim.api.nvim_buf_is_valid(item.bufnr)
      and vim.api.nvim_buf_is_loaded(item.bufnr)
      and vim.bo[item.bufnr].buftype == ""
      and (
         vim.bo[item.bufnr].modified
         or vim.api.nvim_buf_line_count(item.bufnr) >= end_line
      )
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

--DONE
---@param lines string[]
---@return string, string
local function lines_to_display_and_base(lines)
   local first_line = lines[1] or ""
   local display_text = first_line
   if #lines > 1 then
      display_text = string.format("%s (+%d more lines)", first_line, #lines - 1)
   end
   return display_text, table.concat(lines, "\n")
end

--DONE
---@param item vim.quickfix.entry
---@param git_hash? string|nil
---@param timestamp? string|osdate
---@return vim.quickfix.entry|nil
local function qfitem_to_context_item(item, git_hash, timestamp)
   if not item or item.valid == 0 then
      return nil
   end
   if type(item.user_data) == "table" and item.user_data.base_text ~= nil then
      return item
   end

   local start_line, end_line = Utils.qf_range(item)
   local abs = Utils.qf_abspath(item)
   local lines = read_qf_source(item, start_line, end_line)
   local qf_text = item.text or ""
   local display_text, base_text = lines_to_display_and_base(lines)

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

--DONE
---@param items vim.quickfix.entry[]
---@return vim.quickfix.entry[], number
function Utils.qflist_to_context_items(items)
   local converted = {}
   local skipped = 0
   local git_hash = Utils.git_hash()
   local timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
   for _, item in ipairs(items or {}) do
      local ctx_item = qfitem_to_context_item(item, git_hash, timestamp)
      if ctx_item then
         table.insert(converted, ctx_item)
      else
         skipped = skipped + 1
      end
   end
   return converted, skipped
end

--DONE
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

--DONE
---@type table<string, string[]|false>
local git_file_cache = {}

--DONE
---@param root string
---@param relpath string
---@param git_hash string
---@return string[]|nil
local function git_show_file(root, relpath, git_hash)
   if not root or root == "" or not relpath or relpath == "" or not git_hash or git_hash == "" then
      return nil
   end
   local key = root .. "\0" .. git_hash .. "\0" .. relpath
   local cached = git_file_cache[key]
   if cached ~= nil then
      return cached ~= false and cached or nil
   end
   local lines = vim.fn.systemlist({ "git", "-C", root, "show", git_hash .. ":" .. relpath })
   if vim.v.shell_error ~= 0 or type(lines) ~= "table" then
      git_file_cache[key] = false
      return nil
   end
   git_file_cache[key] = lines
   return lines
end

--DONE
---@param root string
---@param relpath string
---@param git_hash string
---@param start_line number
---@param end_line number
---@return string[]|nil
local function git_show_lines(root, relpath, git_hash, start_line, end_line)
   local lines = git_show_file(root, relpath, git_hash)
   if lines == nil then
      return nil
   end
   start_line = math.max(1, start_line or 1)
   end_line = math.max(start_line, end_line or start_line)
   if start_line > #lines then
      return {}
   end
   return vim.list_slice(lines, start_line, math.min(end_line, #lines))
end

---@param lines string[]
---@return string[]
local function normalize_diff_lines(lines)
   if not lines or #lines == 0 then
      return {}
   end
   local out = {}
   for i = 1, #lines do
      out[i] = (lines[i] or ""):gsub("\r$", "")
   end
   local n = #out
   while n > 0 and out[n] == "" do
      n = n - 1
   end
   if n == #out then
      return out
   end
   if n == 0 then
      return {}
   end
   return vim.list_slice(out, 1, n)
end

--DONE
---@param lines string[]
---@return string
local function lines_to_diff_text(lines)
   if not lines or #lines == 0 then
      return ""
   end
   return table.concat(lines, "\n") .. "\n"
end

--DONE
---@param a string[]
---@param b string[]
---@return boolean
local function lines_equal(a, b)
   if #a ~= #b then
      return false
   end
   for i = 1, #a do
      if a[i] ~= b[i] then
         return false
      end
   end
   return true
end

--DONE
---@param text string|nil
---@return string[]|nil
local function split_base_text(text)
   if type(text) ~= "string" or text == "" then
      return nil
   end
   return vim.split(text, "\n", { plain = true })
end

--DONE
---@param root string
---@param item vim.quickfix.entry|ContextItem
---@param opts? RangeDiffOpts
---@return string|nil, string|nil, string|nil, number|nil, string|nil
local function range_diff_spec(root, item, opts)
   opts = opts or {}
   local git_hash, base_text, relpath, bufnr, abs
   if type(item.user_data) == "table" then
     ---@cast item vim.quickfix.entry
      git_hash = item.user_data.git_hash
      base_text = item.user_data.base_text
      relpath = normalize_qf_path(item, root)
      bufnr = item.bufnr
      abs = Utils.qf_abspath(item)
   else
      git_hash = item.git_hash
      base_text = item.base_text
      local filename = item.filename
      if type(filename) ~= "string" or filename == "" then
         return nil
      end
      if filename:sub(1, 1) == "/" then
         abs = vim.fn.fnamemodify(filename, ":p")
         relpath = relativize(abs, root)
      else
         relpath = filename
         abs = root .. "/" .. filename
      end
      bufnr = item.bufnr
   end
   if opts.source_buf then
      bufnr = opts.source_buf
   end
   return git_hash, base_text, relpath, bufnr, abs
end

--DONE
---@param root string
---@param item vim.quickfix.entry|ContextItem
---@param opts? RangeDiffOpts
---@return RangeDiff|nil
function Utils.range_diff(root, item, opts)
   if type(item) ~= "table" or not root or root == "" then
      return nil
   end
   local git_hash, base_text, relpath, bufnr, abs = range_diff_spec(root, item, opts)
   if not git_hash or git_hash == "" or not relpath then
      return nil
   end
   ---@cast item vim.quickfix.entry
   local start_line, end_line = Utils.qf_range(item)
   local old = git_show_lines(root, relpath, git_hash, start_line, end_line)
   if old == nil then
      return nil
   end
   local new = read_qf_source({
      bufnr = bufnr,
      filename = abs,
   }, start_line, end_line)
   old = normalize_diff_lines(old)
   new = normalize_diff_lines(new)
   if lines_equal(old, new) then
      return nil
   end
   -- Still matches the captured snippet: not stale, even if the working tree
   -- already differed from git_hash when the item was pinned.
   local base = split_base_text(base_text)
   if base and lines_equal(normalize_diff_lines(base), new) then
      return nil
   end
   local hunks = vim.text.diff(lines_to_diff_text(old), lines_to_diff_text(new), {
      result_type = "indices",
      algorithm = "histogram",
   })
   if type(hunks) ~= "table" or #hunks == 0 then
      return nil
   end
   ---@type RangeDiff
   return {
      old = old,
      new = new,
      hunks = hunks,
   }
end

--DONE
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
   local display_text, base_text = lines_to_display_and_base(selected_lines)

   return display_text, base_text, start_line, end_line
end

--DONE
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

--DONE
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

--DONE
---@param typ any
---@return ContextStackType
function Utils.list_type(typ)
   if typ == "flow" or typ == "context" then
      return typ
   end
   return "context"
end

--DONE
---@param ctx any
---@return boolean
function Utils.is_flow_view(ctx)
   return type(ctx) == "table" and type(ctx.active_flow) == "string" and ctx.active_flow ~= ""
end

--DONE
--- Parent ContextList snapshot while a nested flow view replaces the qflist.
---@type { title: string, items: vim.quickfix.entry[], context: table }|nil
Utils.flow_parent = nil

--DONE
---@return string
function Utils.current_display_title()
   local info = vim.fn.getqflist({ title = 0, context = 0 })
   local title = info.title or ""
    if title == "" then
       return ""
    end
    local ctx = type(info.context) == "table" and info.context or {}
    local typ = Utils.is_flow_view(ctx) and "flow" or Utils.list_type(ctx.type)
    return title .. " [" .. typ .. "]"
end

--DONE
---@param item vim.quickfix.entry|ContextItem
---@return vim.quickfix.entry|nil
local function as_qf_item(item)
   if type(item) ~= "table" then
      return nil
   end
   if type(item.user_data) == "table" then
     ---@cast item vim.quickfix.entry
      return item
   end
   if not Context.root then
      Context.root = vim.fs.root(0, ".git")
      if not Context.root then
         log.error("not inside a git repository")
         return nil
      end
   end
   ---@cast item ContextItem
   local converted = dbrows_to_qfitems({ item }, Context.root)
   return converted[1]
end

--DONE
---@return number|string|nil
local function qf_list_id()
   local ctx = vim.fn.getqflist({ context = 0 }).context
   if type(ctx) == "table" and ctx.id ~= nil and ctx.id ~= "" then
      return ctx.id
   end
end

--DONE
---@param item vim.quickfix.entry|ContextItem
---@return number|string|nil
local function source_list_id(item)
   if item.list_id ~= nil and item.list_id ~= "" then
      return item.list_id
   end
   return qf_list_id()
end

--DONE
---@param item vim.quickfix.entry|ContextItem
---@return integer|nil
local function source_stack_idx(item)
   local idx = Utils.find_stack_idx_by_id(source_list_id(item))
   if idx then
      return idx
   end
   if #Context.stack > 0 then
      return 1
   end
end

--DONE
---@param exclude_idx integer|nil
---@param prompt string
---@param on_choice fun(idx?: integer)
---@return boolean
local function pick_target_context(exclude_idx, prompt, on_choice)
   if not Context.stack or #Context.stack == 0 then
      log.info("no loaded contexts")
      return false
   end
   ---@type { idx: integer, entry: ContextStackItem }[]
   local choices = {}
   for i, entry in ipairs(Context.stack) do
      if i ~= exclude_idx then
         table.insert(choices, { idx = i, entry = entry })
      end
   end
   if #choices == 0 then
      log.info("no other loaded contexts")
      return false
   end
    vim.ui.select(choices, {
       prompt = prompt,
       format_item = function(item)
          local prefix = item.idx == 1 and "* " or "  "
          return prefix .. (item.entry.title or "")
       end,
    }, function(choice)
       if not choice then
          on_choice(nil)
          return
       end
       local idx = Utils.find_stack_idx(choice.entry)
       if not idx then
          log.error("target context is no longer loaded")
          on_choice(nil)
          return
       end
       on_choice(idx)
    end)
   return true
end

--DONE
---@param qf_item vim.quickfix.entry
---@param new_timestamp boolean
---@return vim.quickfix.entry
local function clone_qf_item(qf_item, new_timestamp)
   local cloned = vim.deepcopy(qf_item)
   local user_data = type(cloned.user_data) == "table" and vim.deepcopy(cloned.user_data) or {}
   user_data.id = nil
   if new_timestamp then
      user_data.timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
   end
   cloned.user_data = user_data
   return cloned
end

--DONE
---@param items vim.quickfix.entry[]
local function replace_qf_items(items)
   vim.fn.setqflist({}, "r", { items = items })
   if Context.Options and Context.Options.trouble then
      require("trouble").refresh("qflist")
   end
end

--DONE
---@param cloned vim.quickfix.entry
local function append_to_current(cloned)
   local qflist = vim.fn.getqflist()
   table.insert(qflist, cloned)
   replace_qf_items(qflist)
   return true
end

--DONE
---@param data ContextList|table
---@return table
local function qf_context_from_list(data)
   return {
      description = data.description,
      id = data.id,
      type = Utils.list_type(data.type),
      flows = data.flows,
   }
end

---@param list_id number|string
---@param items vim.quickfix.entry[]
---@return boolean, any
local function persist_items(list_id, items)
   local ok, previous = pcall(sql.load_list, Context.root, list_id)
   if not ok or not previous then
      return false, previous
   end
   local info = {
      title = previous.title,
      items = items,
      context = qf_context_from_list(previous),
   }
    local conv_ok, new, context = pcall(Utils.qflist_to_context, info, previous)
    if not conv_ok then
       return false, new
    end
   local new_items, updated_items = Utils.qfitems_to_dbrows(items, previous.items, Context.root)
   local deleted_ids = Utils.deleted_item_ids(items, previous.items)
   local upd_ok, err = pcall(
      sql.update_context,
      Context.root,
      context,
      new_items,
      updated_items,
      previous.title,
      deleted_ids
   )
   if not upd_ok then
      return false, err
   end
   return true
end

--DONE
---@param list_id number|string
---@param cloned vim.quickfix.entry
---@return boolean, any
local function append_to_saved(list_id, cloned)
   local loaded, err = Utils.load_as_loaded(list_id)
   if not loaded then
      return false, err
   end
   loaded.items = loaded.items or {}
   table.insert(loaded.items, cloned)
   return persist_items(list_id, loaded.items)
end

--DONE
---@param items vim.quickfix.entry[]
---@param qf_item vim.quickfix.entry
---@return boolean
local function remove_qf_item(items, qf_item)
   local idx = Utils.find_qf_index(items, qf_item)
   if not idx then
      return false
   end
   table.remove(items, idx)
   return true
end

--DONE
---@param qf_item vim.quickfix.entry
---@return boolean
local function remove_from_current(qf_item)
   local qflist = vim.fn.getqflist()
   if remove_qf_item(qflist, qf_item) then
      replace_qf_items(qflist)
      return true
   end
   return false
end

--DONE
---@param list_id number|string
---@param qf_item vim.quickfix.entry
---@return boolean, any
local function remove_from_saved(list_id, qf_item)
   local loaded, err = Utils.load_as_loaded(list_id)
   if not loaded then
      return false, err
   end
   if not remove_qf_item(loaded.items or {}, qf_item) then
      return false
   end
   return persist_items(list_id, loaded.items)
end

--DONE
--/ a.-@param item vim.quickfix.entry|ContextItem
---@param op "move"|"copy"
---@param on_done? fun(success: boolean)
function Utils.transfer_reference(item, op, on_done)
   local qf_item = as_qf_item(item)
   if not qf_item then
      log.error("no context reference to " .. op)
      if on_done then
         on_done(false)
      end
      return
   end

   local exclude_idx = source_stack_idx(item)
   local prompt = op == "move" and "Move reference to:" or "Copy reference to:"
   local opened = pick_target_context(exclude_idx, prompt, function(target_idx)
      if not target_idx then
         if on_done then
            on_done(false)
         end
         return
      end

      local cloned = clone_qf_item(qf_item, op == "copy")
      local target = Context.stack[target_idx]
      local title = target.title or ""
      local added, add_err
      if target_idx == 1 then
         added = append_to_current(cloned)
      elseif not target.id then
         log.error("save the target context before copying into it")
         if on_done then
            on_done(false)
         end
         return
      else
         added, add_err = append_to_saved(target.id, cloned)
      end
      if not added then
         log.error("failed to " .. op .. " reference: " .. tostring(add_err))
         if on_done then
            on_done(false)
         end
         return
      end

      if op == "copy" then
         log.info("copied reference to " .. title)
         if on_done then
            on_done(true)
         end
         return
      end

      local src_idx = source_stack_idx(item)
      local src_id = source_list_id(item)
      local removed = false
      if src_idx == 1 or not src_id then
         removed = remove_from_current(qf_item)
      else
         removed = remove_from_saved(src_id, qf_item)
      end
      if removed then
         log.info("moved reference to " .. title)
         if on_done then
            on_done(true)
         end
         return
      end
      log.info("copied reference to " .. title .. " (could not remove from source)")
      if on_done then
         on_done(false)
      end
   end)
   if not opened and on_done then
      on_done(false)
   end
end

--DONE
---@type { idx: number, bufnr: number, orig_item: vim.quickfix.entry, committing: boolean, augroup: integer }|nil
local range_edit

--DONE
---@param win number
---@return boolean
local function is_normal_file_win(win)
   if not vim.api.nvim_win_is_valid(win) then
      return false
   end
   if vim.w[win].trouble or vim.w[win].trouble_preview then
      return false
   end
   local buf = vim.api.nvim_win_get_buf(win)
   return vim.bo[buf].buftype == ""
end

--DONE
---@param bufnr number
---@return number|nil
local function find_target_win(bufnr)
   for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_buf(win) == bufnr and is_normal_file_win(win) then
         return win
      end
   end
   local prev = vim.fn.win_getid(vim.fn.winnr("#"))
   if is_normal_file_win(prev) then
      return prev
   end
   for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if is_normal_file_win(win) then
         return win
      end
   end
   return nil
end

--DONE
local function cleanup_range_edit()
   local session = range_edit
   range_edit = nil
   if not session then
      return
   end
   if session.augroup then
      pcall(vim.api.nvim_del_augroup_by_id, session.augroup)
   end
   if session.bufnr and vim.api.nvim_buf_is_valid(session.bufnr) then
      pcall(vim.keymap.del, "v", "<CR>", { buffer = session.bufnr })
   end
end

--DONE
local function commit_range_edit()
   local session = range_edit
   if not session then
      return
   end
   session.committing = true

   if not vim.fn.mode():match("^[vV\22]") then
      cleanup_range_edit()
      return
   end

   local start_line = vim.fn.line("v")
   local end_line = vim.fn.line(".")
   if end_line < start_line then
      start_line, end_line = end_line, start_line
   end

   local lines = vim.api.nvim_buf_get_lines(session.bufnr, start_line - 1, end_line, false)
   local display_text, base_text = lines_to_display_and_base(lines)

   local qflist = vim.fn.getqflist()
   local fresh_idx = Utils.find_qf_index(qflist, session.orig_item) or session.idx
   local item = qflist[fresh_idx]
   if not item then
      cleanup_range_edit()
      log.error("could not locate context reference")
      return
   end

   item.lnum = start_line
   item.end_lnum = end_line
   item.text = display_text
   local user_data = type(item.user_data) == "table" and item.user_data or {}
   item.user_data = vim.tbl_extend("force", user_data, {
      base_text = base_text,
      display_text = display_text,
      git_hash = Utils.git_hash(),
      timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
   })
   qflist[fresh_idx] = item
   vim.fn.setqflist({}, "r", { items = qflist })
   if Context.Options and Context.Options.trouble then
      require("trouble").refresh("qflist")
   end
   cleanup_range_edit()
   vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
   log.info("updated context reference lines")
end

--DONE
---@param idx number
function Utils.edit_reference_lines(idx)
   local qflist = vim.fn.getqflist()
   local item = qflist[idx]
   if not item then
      log.error("no context reference under cursor")
      return
   end

   local bufnr = item.bufnr
   if not (bufnr and bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr)) then
      local abs = Utils.qf_abspath(item)
      if not abs or abs == "" then
         log.error("no file for context reference")
         return
      end
      bufnr = vim.fn.bufadd(abs)
   end
   if not vim.api.nvim_buf_is_loaded(bufnr) then
      vim.fn.bufload(bufnr)
   end
   if vim.bo[bufnr].buflisted == false then
      vim.bo[bufnr].buflisted = true
   end

   local start_line, end_line = Utils.qf_range(item)
   local line_count = vim.api.nvim_buf_line_count(bufnr)
   start_line = math.max(1, math.min(start_line, line_count))
   end_line = math.max(1, math.min(end_line, line_count))
   if end_line < start_line then
      end_line = start_line
   end

   cleanup_range_edit()
   local orig_item = vim.deepcopy(item)

   vim.schedule(function()
      local win = find_target_win(bufnr)
      if not win then
         vim.cmd("botright split")
         win = vim.api.nvim_get_current_win()
      end
      vim.api.nvim_win_set_buf(win, bufnr)
      vim.api.nvim_set_current_win(win)

      vim.api.nvim_win_call(win, function()
         vim.cmd(string.format("normal! %dGV%dG", end_line, start_line))
      end)

      range_edit = {
         idx = idx,
         bufnr = bufnr,
         orig_item = orig_item,
         committing = false,
      }

      vim.keymap.set("v", "<CR>", function()
         commit_range_edit()
      end, { buffer = bufnr, nowait = true, silent = true, desc = "Update context reference lines" })

      local augroup = vim.api.nvim_create_augroup("NvimContextRangeEdit", { clear = true })
      range_edit.augroup = augroup

      vim.api.nvim_create_autocmd("ModeChanged", {
         group = augroup,
         pattern = "[vV\22]:n",
         callback = function()
            if not range_edit or range_edit.committing then
               return
            end
            if vim.api.nvim_get_current_buf() ~= bufnr then
               return
            end
            cleanup_range_edit()
         end,
      })
      vim.api.nvim_create_autocmd("BufWipeout", {
         group = augroup,
         buffer = bufnr,
         callback = function()
            cleanup_range_edit()
         end,
      })
   end)
end

--DONE
---@param data ContextList
---@return LoadedContext
local function loaded_from_list(data)
   return {
      title = data.title or "",
      items = dbrows_to_qfitems(data.items, Context.root),
      context = qf_context_from_list(data),
   }
end

--DONE
---@param id number|string
---@return LoadedContext|nil, any
function Utils.load_as_loaded(id)
   local ok, data = pcall(sql.load_list, Context.root, id)
   if not ok or not data then
      return nil, data
   end
   return loaded_from_list(data)
end

--DONE
---@param loaded LoadedContext
---@return ContextStackItem
local function stack_item_from_loaded(loaded)
   local ctx = type(loaded.context) == "table" and loaded.context or {}
   local id = ctx.id
   if id == "" then
      id = nil
   end
   return { id = id, title = loaded.title or "" }
end

--DONE
---@param entry LoadedContext
---@param action string
---@param opts? { keep_flow_parent?: boolean }
function Utils.apply_loaded(entry, action, opts)
   if not (opts and opts.keep_flow_parent) then
      Utils.flow_parent = nil
   end
   vim.fn.setqflist({}, action, {
      title = entry.title,
      items = entry.items or {},
      context = entry.context,
   })
   if Context.Options and Context.Options.trouble then
      require("trouble").refresh("qflist")
   end
end

--DONE
---@param new_context table
function Utils.write_qf_context(new_context)
   vim.fn.setqflist({}, "r", { context = new_context })
   if Context.Options and Context.Options.trouble then
      require("trouble").refresh("qflist")
   end
end

--DONE
---@param id number|string|nil
---@return integer|nil
function Utils.find_stack_idx_by_id(id)
   if id == nil or id == "" then
      return nil
   end
   for i, entry in ipairs(Context.stack) do
      if entry.id == id then
         return i
      end
   end
end

--DONE
---@param idx integer
local function move_to_top(idx)
   if idx == 1 then
      return
   end
   local entry = table.remove(Context.stack, idx)
   table.insert(Context.stack, 1, entry)
end

--DONE
---@param entry ContextStackItem
---@return boolean
function Utils.showing_stack_entry(entry)
   local info = vim.fn.getqflist({ context = 0, title = 0 })
   local ctx = type(info.context) == "table" and info.context or {}
   if Utils.is_flow_view(ctx) or Utils.list_type(ctx.type) ~= "context" then
      return false
   end
   if entry.id then
      return ctx.id == entry.id
   end
   return (ctx.id == nil or ctx.id == "") and (info.title or "") == entry.title
end

---@param t any
---@return table
local function tbl_or_empty(t)
   if type(t) ~= "table" or vim.tbl_isempty(t) then
      return {}
   end
   return t
end

---@param item vim.quickfix.entry
---@return table
local function item_fingerprint(item)
   local ud = type(item.user_data) == "table" and item.user_data or {}
   local lnum, end_lnum = Utils.qf_range(item)
   return {
      path = normalize_qf_path(item, Context.root) or item.filename or "",
      lnum = lnum,
      end_lnum = end_lnum,
      description = ud.description or "",
      base_text = ud.base_text or "",
      display_text = ud.display_text or "",
   }
end

---@param a vim.quickfix.entry[]
---@param b vim.quickfix.entry[]
---@return boolean
local function qf_items_match(a, b)
   if #a ~= #b then
      return false
   end
   for i = 1, #a do
      if not vim.deep_equal(item_fingerprint(a[i]), item_fingerprint(b[i])) then
         return false
      end
   end
   return true
end

--- Live qflist differs from the last saved DB row (or an unsaved list has content).
--- Flow views are dirty only when nested flows differ from the parent DB row.
--- Item ids are ignored (they are not stamped onto the qflist until reload, so a
--- post-save list would otherwise always look dirty).
---@return boolean
local function current_is_dirty()
   local info = vim.fn.getqflist({ title = 0, items = 0, context = 0 })
   local ctx = type(info.context) == "table" and info.context or {}
   if Utils.is_flow_view(ctx) then
      local id = ctx.id or (Context.stack[1] and Context.stack[1].id)
      if id == nil or id == "" then
         return type(ctx.flows) == "table" and not vim.tbl_isempty(ctx.flows)
      end
      if not Context.root then
         return type(ctx.flows) == "table" and not vim.tbl_isempty(ctx.flows)
      end
      local loaded = Utils.load_as_loaded(id)
      if not loaded then
         return true
      end
      local lctx = type(loaded.context) == "table" and loaded.context or {}
      return not vim.deep_equal(tbl_or_empty(ctx.flows), tbl_or_empty(lctx.flows))
   end
   if Utils.list_type(ctx.type) ~= "context" then
      return false
   end
   local items = info.items or {}
   local id = ctx.id
   if id == nil or id == "" then
      if #items > 0 then
         return true
      end
      if (ctx.description or "") ~= "" then
         return true
      end
      if type(ctx.flows) == "table" and not vim.tbl_isempty(ctx.flows) then
         return true
      end
      return false
   end
   if not Context.root then
      return #items > 0
   end
   local loaded = Utils.load_as_loaded(id)
   if not loaded then
      return true
   end
   if (info.title or "") ~= (loaded.title or "") then
      return true
   end
   local lctx = type(loaded.context) == "table" and loaded.context or {}
   if (ctx.description or "") ~= (lctx.description or "") then
      return true
   end
   if not vim.deep_equal(tbl_or_empty(ctx.flows), tbl_or_empty(lctx.flows)) then
      return true
   end
   return not qf_items_match(items, loaded.items or {})
end

--DONE
---@param proceed fun()
function Utils.confirm_leave_current(proceed)
   if not current_is_dirty() then
      proceed()
      return
   end
   local title = vim.fn.getqflist({ title = 0 }).title
   if title == nil or title == "" then
      title = "untitled"
   end
   vim.ui.select({ "Save", "Discard", "Cancel" }, {
      prompt = string.format("Context '%s' has unsaved changes. Save before switching?", title),
   }, function(choice)
      if choice == "Save" then
         if Context.SaveContext() then
            proceed()
         end
      elseif choice == "Discard" then
         proceed()
      end
   end)
end

--DONE
---@param idx integer
---@param action string
function Utils.activate_idx(idx, action)
   local entry = Context.stack[idx]
   if not entry then
      return
   end
   if idx == 1 and Utils.showing_stack_entry(entry) then
      return
   end
   move_to_top(idx)
   entry = Context.stack[1]
   if entry.id then
      local loaded, err = Utils.load_as_loaded(entry.id)
      if not loaded then
         log.error("failed to load context: " .. tostring(err))
         return
      end
      entry.title = loaded.title
      Utils.apply_loaded(loaded, action)
      return
   end
   Utils.apply_loaded({
      title = entry.title,
      items = {},
      context = { type = "context" },
   }, action)
end

--DONE
---@param entry LoadedContext
---@param action string
function Utils.push_loaded(entry, action)
   table.insert(Context.stack, 1, stack_item_from_loaded(entry))
   Utils.apply_loaded(entry, action)
end

--DONE
---@param list_id number|string|nil
---@param after? fun(ok: boolean)
---@return boolean
function Utils.activate_or_push(list_id, after)
   if list_id == nil or list_id == "" then
      log.error("reference has no parent context")
      if after then
         after(false)
      end
      return false
   end
   local stacked_idx = Utils.find_stack_idx_by_id(list_id)
   if stacked_idx then
      local entry = Context.stack[stacked_idx]
      if stacked_idx == 1 and Utils.showing_stack_entry(entry) then
         log.info("loaded context: " .. entry.title)
         if after then
            after(true)
         end
         return true
      end
      Utils.confirm_leave_current(function()
         Utils.activate_idx(stacked_idx, "r")
         log.info("loaded context: " .. Context.stack[1].title)
         if after then
            after(true)
         end
      end)
      return true
   end
   Utils.confirm_leave_current(function()
      local loaded, err = Utils.load_as_loaded(list_id)
      if not loaded then
         log.error("failed to load context: " .. tostring(err))
         if after then
            after(false)
         end
         return
      end
      Utils.push_loaded(loaded, " ")
      log.info("loaded context: " .. loaded.title)
      if after then
         after(true)
      end
   end)
   return true
end

--DONE
function Utils.adopt_current_qf()
   local info = vim.fn.getqflist({ title = 0, context = 0 })
   local ctx = type(info.context) == "table" and info.context or {}
   local id = ctx.id
   if id == "" then
      id = nil
   end
   table.insert(Context.stack, 1, { id = id, title = info.title or "" })
end

--DONE
---@param entry ContextStackItem
---@return integer|nil
function Utils.find_stack_idx(entry)
   if entry.id ~= nil and entry.id ~= "" then
      local idx = Utils.find_stack_idx_by_id(entry.id)
      if idx then
         return idx
      end
   end
   for i, stacked in ipairs(Context.stack) do
      if stacked == entry then
         return i
      end
   end
   for i, stacked in ipairs(Context.stack) do
      if stacked.title == entry.title then
         return i
      end
   end
end

--DONE
---@return vim.quickfix.entry|nil
local function current_trouble_qf_item()
   if vim.bo.filetype ~= "trouble" and not vim.w.trouble then
      return nil
   end
   local ok, View = pcall(require, "trouble.view")
   if not ok then
      return nil
   end
   local buf = vim.api.nvim_get_current_buf()
   for _, entry in ipairs(View.get({ open = true, mode = "qflist" }) or {}) do
      local view = entry.view
      if view and view.win and view.win.buf == buf and type(view.at) == "function" then
         local at = view:at()
         local item = at and at.item
         if type(item) == "table" then
            return item.item or item
         end
      end
   end
end

--DONE
---@param arg1 any
---@param arg2 any
---@return number|nil, vim.quickfix.entry|nil
function Utils.resolve_list_item(arg1, arg2)
   local raw
   if type(arg1) == "table" then
      local ctx = arg1
      if arg1.item == nil and type(arg2) == "table" then
         ctx = arg2
      end
      raw = ctx.item and (ctx.item.item or ctx.item)
   elseif vim.bo.filetype == "qf" then
      local qflist = vim.fn.getqflist()
      local idx = arg1 or vim.fn.line(".")
      return idx, qflist[idx]
   else
      raw = current_trouble_qf_item()
   end
   if type(raw) ~= "table" then
      return nil
   end
   local qflist = vim.fn.getqflist()
   local idx = Utils.find_qf_index(qflist, raw)
   return idx, idx and qflist[idx] or nil
end

--DONE
---@param item vim.quickfix.entry
---@param idx integer
---@return number
function Utils.item_ref_id(item, idx)
   local ud = item.user_data
   if type(ud) == "table" and ud.id ~= nil then
      return ud.id
   end
   return idx
end

--DONE
---@param arg1 any
---@param arg2 any
---@return FlowEndpoint[]|nil
function Utils.resolve_flow_endpoints(arg1, arg2)
   local qflist = vim.fn.getqflist()
   if vim.bo.filetype == "qf" and type(arg1) ~= "table" then
      local a = arg1 or vim.fn.line(".")
      local b = arg2 or a
      if a > b then
         a, b = b, a
      end
      local endpoints = {}
      for i = a, b do
         local item = qflist[i]
         if type(item) == "table" then
            table.insert(endpoints, { idx = i, item = item, id = Utils.item_ref_id(item, i) })
         end
      end
      if #endpoints == 0 then
         return nil
      end
      return endpoints
   end
   local idx, item = Utils.resolve_list_item(arg1, arg2)
   if not item or not idx then
      return nil
   end
   return { { idx = idx, item = item, id = Utils.item_ref_id(item, idx) } }
end

--DONE
---@param flow ContextFlow
---@param id number
---@param idx integer
---@return boolean
function Utils.flow_has_item(flow, id, idx)
   if type(flow.items) ~= "table" then
      return false
   end
   for _, pair in ipairs(flow.items) do
      if pair[1] == id or pair[1] == idx or pair[2] == id or pair[2] == idx then
         return true
      end
   end
   return false
end

--DONE
---@param items number[][]
---@param from number
---@param to number
---@return boolean
function Utils.connection_exists(items, from, to)
   for _, pair in ipairs(items) do
      if pair[1] == from and pair[2] == to then
         return true
      end
   end
   return false
end

--DONE
---@param item vim.quickfix.entry
---@return string
function Utils.format_flow_endpoint(item)
   local name = item.filename or ""
   local lnum = item.lnum or 0
   local text = item.text or ""
   if text ~= "" then
      return string.format("%s:%d %s", name, lnum, text)
   end
   return string.format("%s:%d", name, lnum)
end

--DONE
---@param flow ContextFlow
---@param qflist vim.quickfix.entry[]
---@return vim.quickfix.entry[]
local function flow_to_qfitems(flow, qflist)
   local items = {}
   if type(flow.items) ~= "table" then
      return items
   end
   local seen = {}
   local function append_id(flow_id)
      if type(flow_id) ~= "number" then
         return
      end
      for i, item in ipairs(qflist) do
         local id = Utils.item_ref_id(item, i)
         if id == flow_id or i == flow_id then
            if not seen[i] then
               seen[i] = true
               table.insert(items, item)
            end
            return
         end
      end
   end
   for _, pair in ipairs(flow.items) do
      append_id(pair[1])
      append_id(pair[2])
   end
   return items
end

--DONE
---@param flow ContextFlow
function Utils.activate_flow(flow)
   local info = vim.fn.getqflist({ context = 0, title = 0, items = 0 })
   local ctx = type(info.context) == "table" and info.context or {}
   if not Utils.flow_parent then
      local parent_ctx = vim.deepcopy(ctx)
      parent_ctx.active_flow = nil
      Utils.flow_parent = {
         title = info.title or "",
         items = info.items or {},
         context = parent_ctx,
      }
   end

   local items = flow_to_qfitems(flow, Utils.flow_parent.items)
   if #items == 0 then
      log.info("flow has no items: " .. (flow.title or ""))
      if not Utils.is_flow_view(ctx) then
         Utils.flow_parent = nil
      end
      return
   end

   local view_ctx = vim.deepcopy(Utils.flow_parent.context)
   view_ctx.flows = ctx.flows or Utils.flow_parent.context.flows
   view_ctx.id = ctx.id or Utils.flow_parent.context.id
   view_ctx.active_flow = flow.title

   ---@type LoadedContext
   local loaded = {
      title = flow.title or "",
      items = items,
      context = view_ctx,
   }

   Utils.apply_loaded(loaded, "r", { keep_flow_parent = true })
   if vim.bo.filetype == "qf" then
      vim.wo.winbar = Utils.current_display_title()
   end
   log.info("loaded flow: " .. loaded.title)
end

--DONE
---@param idx number
function Utils.delete_qf_index(idx)
   local qflist = vim.fn.getqflist()
   if not idx or not qflist[idx] then
      log.error("no context reference under cursor")
      return
   end
   table.remove(qflist, idx)
   vim.fn.setqflist({}, "r", { items = qflist })
   if Context.Options and Context.Options.trouble then
      require("trouble").refresh("qflist")
   end
   log.info("deleted context reference")
end

--DONE
---@param idx? number
---@param op "move"|"copy"
function Utils.transfer_qf_reference(idx, op)
   local name = op == "move" and "MoveReference" or "CopyReference"
   if idx == nil and vim.bo.filetype ~= "qf" then
      log.error(name .. " must be run from the quickfix list")
      return
   end
   local qflist = vim.fn.getqflist()
   local item = qflist[idx or vim.fn.line(".")]
   if not item then
      log.error("no context reference under cursor")
      return
   end
   Utils.transfer_reference(item, op)
end

return Utils
