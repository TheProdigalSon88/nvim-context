local sql = require("nvim-context.sql")
local utils = require("nvim-context.utils")
local buffer = require("nvim-context.buffer")
local log = require("nvim-context.log")

local Context = {}
---@type ContextStackItem[]
Context.stack = {}

local STACK_TYPES = { "context", "flow" }

---@param typ any
---@return ContextStackType
local function list_type(typ)
   if typ == "flow" or typ == "context" then
      return typ
   end
   return "context"
end

---@param ctx any
---@return boolean
local function is_flow_view(ctx)
   return type(ctx) == "table" and type(ctx.active_flow) == "string" and ctx.active_flow ~= ""
end

--- Parent ContextList snapshot while a nested flow view replaces the qflist.
---@type { title: string, items: vim.quickfix.entry[], context: table }|nil
local flow_parent = nil

---@return string
local function current_display_title()
   local info = vim.fn.getqflist({ title = 0, context = 0 })
   local title = info.title or ""
    if title == "" then
       return ""
    end
    local ctx = type(info.context) == "table" and info.context or {}
    local typ = is_flow_view(ctx) and "flow" or list_type(ctx.type)
    return title .. " [" .. typ .. "]"
end

---@param item vim.quickfix.entry|ContextItem
---@param op "move"|"copy"
---@param on_done? fun(success: boolean)
local transfer_reference

---@type ContextOptions
local defaults = {
   trouble = false,
   statusline = false,
   diagram = {
      enabled = false,
      snippets = {},
      image = {
         backend = "kitty",
      },
      renderer_options = {
         mermaid = { theme = "default" },
      },
   },
}

vim.api.nvim_create_autocmd("FileType", {
   pattern = "qf",
   callback = function()
      vim.wo.winbar = current_display_title()
   end,
})

local function setup_diagram_plugins()
   local image_ok, image = pcall(require, "image")
   if not image_ok then
      log.error("diagram.enabled but image.nvim is not installed")
      return
   end
   image.setup(Context.Options.diagram.image)

   local diagram_ok, diagram = pcall(require, "diagram")
   if not diagram_ok then
      log.error("diagram.enabled but diagram.nvim is not installed")
      return
   end
   local integrations = Context.Options.diagram.integrations or { require("diagram.integrations.markdown") }
   diagram.setup({
      integrations = integrations,
      renderer_options = Context.Options.diagram.renderer_options,
   })
end

function Context.setup(opts)
   Context.Options = vim.tbl_deep_extend("force", defaults, opts or {})
   require("nvim-context.diff").setup()
   require("nvim-context.qf").setup()
   if Context.Options.diagram.enabled then
      setup_diagram_plugins()
   end
   if Context.Options.trouble then
      require("nvim-context.trouble").setup()
   end
end

function Context.AddReference()
   if not Context.root then
      Context.root = vim.fs.root(0, ".git")
      if not Context.root then
         log.error("not inside a git repository")
         return
      end
   end
   local bufnr = vim.api.nvim_get_current_buf()
   local display_text, base_text, start_line, end_line = utils.getLines(bufnr)
   ---@type ReferenceBuffer
   local referenceBuffer = {
      default = "",
      code = base_text,
      source_buf = bufnr,
      diagram_keymap = Context.Options.diagram.enabled and Context.Options.diagram.keymap or nil,
      diagram_enabled = Context.Options.diagram.enabled,
      diagram_snippets = Context.Options.diagram.enabled and Context.Options.diagram.snippets or nil,
   }
   buffer.open_reference_editor(referenceBuffer, function(description)
      ---@type vim.quickfix.entry
      local item = {
         filename = utils.get_file_path(bufnr, Context.root),
         bufnr = bufnr,
         lnum = start_line,
         end_lnum = end_line,
         col = 1,
         text = display_text,
         ---@type UserData
         user_data = {
           id = nil,
            description = description,
            base_text = base_text,
            display_text = display_text,
            git_hash = utils.git_hash(),
            timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
         },
      }

      vim.fn.setqflist({ item }, "a")
      if Context.Options.trouble then
         require("trouble").refresh("qflist")
      end
      log.info("added reference to context")
   end)
end

---@param idx? number
function Context.EditReference(idx)
   if idx == nil and vim.bo.filetype ~= "qf" then
      return
   end
   local qflist = vim.fn.getqflist()
   ---@type vim.quickfix.entry
   local item = qflist[idx or vim.fn.line(".")]
   if not item then
      return
   end
   ---@type UserData
   local user_data = item.user_data
   local current_description = user_data.description
   local base_text = user_data.base_text
   local display_text = user_data.display_text
   local id = user_data.id
   local current_idx = idx or vim.fn.line(".")
   ---@type ReferenceBuffer
   local referenceBuffer = {
      default = current_description,
      code = base_text,
      source_buf = item.bufnr,
      diagram_keymap = Context.Options.diagram.enabled and Context.Options.diagram.keymap or nil,
      diagram_enabled = Context.Options.diagram.enabled,
      diagram_snippets = Context.Options.diagram.enabled and Context.Options.diagram.snippets or nil,
   }

   referenceBuffer.on_move = function(on_done)
      transfer_reference(item, "move", on_done)
   end
   referenceBuffer.on_copy = function(on_done)
      transfer_reference(item, "copy", on_done)
   end

   buffer.open_reference_editor(referenceBuffer, function(description)
      if description == nil then
         return
      end
      item.text = display_text
      item.user_data = vim.tbl_extend("force", user_data, {
         description = description,
         base_text = base_text,
         display_text = display_text,
         id = id,
      })
      local updated_qflist = vim.fn.getqflist()
      local fresh_idx = utils.find_qf_index(updated_qflist, item) or current_idx
      updated_qflist[fresh_idx] = item
      vim.fn.setqflist({}, "r", { items = updated_qflist })
      if Context.Options.trouble then
         require("trouble").refresh("qflist")
      end
      log.info("updated context reference")
   end)
end

---@type { idx: number, bufnr: number, orig_item: vim.quickfix.entry, committing: boolean, augroup: integer }|nil
local range_edit

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
   local display_text, base_text = utils.lines_to_display_and_base(lines)

   local qflist = vim.fn.getqflist()
   local fresh_idx = utils.find_qf_index(qflist, session.orig_item) or session.idx
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
      git_hash = utils.git_hash(),
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

---@param idx number
local function edit_reference_lines(idx)
   local qflist = vim.fn.getqflist()
   local item = qflist[idx]
   if not item then
      log.error("no context reference under cursor")
      return
   end

   local bufnr = item.bufnr
   if not (bufnr and bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr)) then
      local abs = utils.qf_abspath(item)
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

   local start_line, end_line = utils.qf_range(item)
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

---@param idx? number
function Context.EditReferenceLines(idx)
   if vim.bo.filetype ~= "qf" then
      log.error("EditReferenceLines must be run from the quickfix list")
      return
   end
   edit_reference_lines(idx or vim.fn.line("."))
end

---@param data ContextList|table
---@return table
local function qf_context_from_list(data)
   return {
      description = data.description,
      id = data.id,
      type = list_type(data.type),
      flows = data.flows,
   }
end

---@param data ContextList
---@return LoadedContext
local function loaded_from_list(data)
   return {
      title = data.title or "",
      items = utils.dbrows_to_qfitems(data.items, Context.root),
      context = qf_context_from_list(data),
   }
end

---@param id number|string
---@return LoadedContext|nil, any
local function load_as_loaded(id)
   local ok, data = pcall(sql.load_list, Context.root, id)
   if not ok or not data then
      return nil, data
   end
   return loaded_from_list(data)
end

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

---@param entry LoadedContext
---@param action string
---@param opts? { keep_flow_parent?: boolean }
local function apply_loaded(entry, action, opts)
   if not (opts and opts.keep_flow_parent) then
      flow_parent = nil
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

---@param new_context table
local function write_qf_context(new_context)
   vim.fn.setqflist({}, "r", { context = new_context })
   if Context.Options and Context.Options.trouble then
      require("trouble").refresh("qflist")
   end
end

---@return number|string|nil
local function qf_list_id()
   local ctx = vim.fn.getqflist({ context = 0 }).context
   if type(ctx) == "table" and ctx.id ~= nil and ctx.id ~= "" then
      return ctx.id
   end
end

---@param id number|string|nil
---@return integer|nil
local function find_stack_idx_by_id(id)
   if id == nil or id == "" then
      return nil
   end
   for i, entry in ipairs(Context.stack) do
      if entry.id == id then
         return i
      end
   end
end

---@param idx integer
local function move_to_top(idx)
   if idx == 1 then
      return
   end
   local entry = table.remove(Context.stack, idx)
   table.insert(Context.stack, 1, entry)
end

---@param entry ContextStackItem
---@return boolean
local function showing_stack_entry(entry)
   local info = vim.fn.getqflist({ context = 0, title = 0 })
   local ctx = type(info.context) == "table" and info.context or {}
   if is_flow_view(ctx) or list_type(ctx.type) ~= "context" then
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
   local lnum, end_lnum = utils.qf_range(item)
   return {
      path = utils.normalize_qf_path(item, Context.root) or item.filename or "",
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
   if is_flow_view(ctx) then
      local id = ctx.id or (Context.stack[1] and Context.stack[1].id)
      if id == nil or id == "" then
         return type(ctx.flows) == "table" and not vim.tbl_isempty(ctx.flows)
      end
      if not Context.root then
         return type(ctx.flows) == "table" and not vim.tbl_isempty(ctx.flows)
      end
      local loaded = load_as_loaded(id)
      if not loaded then
         return true
      end
      local lctx = type(loaded.context) == "table" and loaded.context or {}
      return not vim.deep_equal(tbl_or_empty(ctx.flows), tbl_or_empty(lctx.flows))
   end
   if list_type(ctx.type) ~= "context" then
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
   local loaded = load_as_loaded(id)
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

---@param proceed fun()
local function confirm_leave_current(proceed)
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

---@param idx integer
---@param action string
local function activate_idx(idx, action)
   local entry = Context.stack[idx]
   if not entry then
      return
   end
   if idx == 1 and showing_stack_entry(entry) then
      return
   end
   move_to_top(idx)
   entry = Context.stack[1]
   if entry.id then
      local loaded, err = load_as_loaded(entry.id)
      if not loaded then
         log.error("failed to load context: " .. tostring(err))
         return
      end
      entry.title = loaded.title
      apply_loaded(loaded, action)
      return
   end
   apply_loaded({
      title = entry.title,
      items = {},
      context = { type = "context" },
   }, action)
end

---@param entry LoadedContext
---@param action string
local function push_loaded(entry, action)
   table.insert(Context.stack, 1, stack_item_from_loaded(entry))
   apply_loaded(entry, action)
end

---@param list_id number|string|nil
---@param after? fun(ok: boolean)
---@return boolean
local function activate_or_push(list_id, after)
   if list_id == nil or list_id == "" then
      log.error("reference has no parent context")
      if after then
         after(false)
      end
      return false
   end
   local stacked_idx = find_stack_idx_by_id(list_id)
   if stacked_idx then
      local entry = Context.stack[stacked_idx]
      if stacked_idx == 1 and showing_stack_entry(entry) then
         log.info("loaded context: " .. entry.title)
         if after then
            after(true)
         end
         return true
      end
      confirm_leave_current(function()
         activate_idx(stacked_idx, "r")
         log.info("loaded context: " .. Context.stack[1].title)
         if after then
            after(true)
         end
      end)
      return true
   end
   confirm_leave_current(function()
      local loaded, err = load_as_loaded(list_id)
      if not loaded then
         log.error("failed to load context: " .. tostring(err))
         if after then
            after(false)
         end
         return
      end
      push_loaded(loaded, " ")
      log.info("loaded context: " .. loaded.title)
      if after then
         after(true)
      end
   end)
   return true
end

local function adopt_current_qf()
   local info = vim.fn.getqflist({ title = 0, context = 0 })
   local ctx = type(info.context) == "table" and info.context or {}
   local id = ctx.id
   if id == "" then
      id = nil
   end
   table.insert(Context.stack, 1, { id = id, title = info.title or "" })
end

---@param item vim.quickfix.entry|ContextItem
---@return vim.quickfix.entry|nil
local function as_qf_item(item)
   if type(item) ~= "table" then
      return nil
   end
   if type(item.user_data) == "table" then
      return item
   end
   if not Context.root then
      Context.root = vim.fs.root(0, ".git")
      if not Context.root then
         log.error("not inside a git repository")
         return nil
      end
   end
   local converted = utils.dbrows_to_qfitems({ item }, Context.root)
   return converted[1]
end

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

---@param entry ContextStackItem
---@return integer|nil
local function find_stack_idx(entry)
   if entry.id ~= nil and entry.id ~= "" then
      local idx = find_stack_idx_by_id(entry.id)
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

---@param item vim.quickfix.entry|ContextItem
---@return number|string|nil
local function source_list_id(item)
   if item.list_id ~= nil and item.list_id ~= "" then
      return item.list_id
   end
   return qf_list_id()
end

---@param item vim.quickfix.entry|ContextItem
---@return integer|nil
local function source_stack_idx(item)
   local idx = find_stack_idx_by_id(source_list_id(item))
   if idx then
      return idx
   end
   if #Context.stack > 0 then
      return 1
   end
end

---@param items vim.quickfix.entry[]
---@param qf_item vim.quickfix.entry
---@return boolean
local function remove_qf_item(items, qf_item)
   local idx = utils.find_qf_index(items, qf_item)
   if not idx then
      return false
   end
   table.remove(items, idx)
   return true
end

---@param items vim.quickfix.entry[]
local function replace_qf_items(items)
   vim.fn.setqflist({}, "r", { items = items })
   if Context.Options and Context.Options.trouble then
      require("trouble").refresh("qflist")
   end
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
    local conv_ok, new, context = pcall(utils.qflist_to_context, info, previous)
    if not conv_ok then
       return false, new
    end
   local new_items, updated_items = utils.qfitems_to_dbrows(items, previous.items, Context.root)
   local deleted_ids = utils.deleted_item_ids(items, previous.items)
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

---@param cloned vim.quickfix.entry
local function append_to_current(cloned)
   local qflist = vim.fn.getqflist()
   table.insert(qflist, cloned)
   replace_qf_items(qflist)
   return true
end

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

---@param list_id number|string
---@param cloned vim.quickfix.entry
---@return boolean, any
local function append_to_saved(list_id, cloned)
   local loaded, err = load_as_loaded(list_id)
   if not loaded then
      return false, err
   end
   loaded.items = loaded.items or {}
   table.insert(loaded.items, cloned)
   return persist_items(list_id, loaded.items)
end

---@param list_id number|string
---@param qf_item vim.quickfix.entry
---@return boolean, any
local function remove_from_saved(list_id, qf_item)
   local loaded, err = load_as_loaded(list_id)
   if not loaded then
      return false, err
   end
   if not remove_qf_item(loaded.items or {}, qf_item) then
      return false
   end
   return persist_items(list_id, loaded.items)
end

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
       local idx = find_stack_idx(choice.entry)
       if not idx then
          log.error("target context is no longer loaded")
          on_choice(nil)
          return
       end
       on_choice(idx)
    end)
   return true
end

---@param item vim.quickfix.entry|ContextItem
---@param op "move"|"copy"
---@param on_done? fun(success: boolean)
transfer_reference = function(item, op, on_done)
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

function Context.LoadContext()
   if not Context.root then
      Context.root = vim.fs.root(0, ".git")
      if not Context.root then
         log.error("not inside a git repository")
         return
      end
   end

   ---@type boolean,ContextListItem[]
   local ok, titles = pcall(sql.list_titles, Context.root)
   if not ok then
      log.error("failed to read contexts: " .. tostring(titles))
      return
   end

   ---@type ContextListItem
   local new_context = { title = "+ New Context", id = "" }
   local titles_with_new = vim.list_extend({}, titles)
   table.insert(titles_with_new, new_context)

   vim.ui.select(titles_with_new, {
      prompt = "Load context:",
      format_item = function(item)
         return item.title
      end,
   }, function(choice)
      if not choice then
         return
      end

      if choice.title == new_context.title then
         confirm_leave_current(function()
            vim.ui.input({ prompt = "New context title: " }, function(title)
               if title == nil or title == "" then
                  log.error("context must have title")
                  return
               end
               push_loaded({ title = title, items = {}, context = { type = "context" } }, " ")
               log.info("created context " .. title)
            end)
         end)
         return
      end

      local stacked_idx = find_stack_idx_by_id(choice.id)
      if stacked_idx then
         if stacked_idx == 1 and showing_stack_entry(Context.stack[1]) then
            log.info("loaded context: " .. choice.title)
            return
         end
         confirm_leave_current(function()
            activate_idx(stacked_idx, "r")
            log.info("loaded context: " .. choice.title)
         end)
         return
      end

      confirm_leave_current(function()
         local loaded, err = load_as_loaded(choice.id)
         if not loaded then
            log.error("failed to load context" .. tostring(err))
            return
         end
         if loaded.title == "" then
            loaded.title = choice.title
         end
         push_loaded(loaded, " ")
         log.info("loaded context: " .. choice.title)
      end)
    end)
end

function Context.DeleteContext()
   if not Context.root then
      Context.root = vim.fs.root(0, ".git")
      if not Context.root then
         log.error("not inside a git repository")
         return
      end
   end

   ---@type boolean,ContextListItem[]
   local ok, titles = pcall(sql.list_titles, Context.root)
   if not ok then
      log.error("failed to read contexts: " .. tostring(titles))
      return
   end
   if not titles or #titles == 0 then
      log.info("no saved contexts")
      return
   end

   vim.ui.select(titles, {
      prompt = "Delete context:",
      format_item = function(item)
         return item.title
      end,
   }, function(choice)
      if not choice then
         return
      end

      vim.ui.select({ "Cancel", "Delete from database" }, {
         prompt = string.format("Delete '%s'? This removes it from the database.", choice.title),
      }, function(confirm)
         if confirm ~= "Delete from database" then
            return
         end

         local del_ok, err = pcall(sql.delete_context, Context.root, choice.id)
         if not del_ok then
            log.error("failed to delete context: " .. tostring(err))
            return
         end

          local stacked_idx = find_stack_idx_by_id(choice.id)
          if stacked_idx then
             local was_current = stacked_idx == 1
             table.remove(Context.stack, stacked_idx)
             if was_current then
                if #Context.stack > 0 then
                   activate_idx(1, "r")
                else
                   apply_loaded({ title = "", items = {}, context = {} }, "r")
                end
             end
          end

         log.info("deleted context: " .. choice.title)
      end)
   end)
end

function Context.PickContext()
   if not Context.stack or #Context.stack == 0 then
      log.info("no loaded contexts")
      return
   end

   vim.ui.select(Context.stack, {
      prompt = "Switch context:",
      format_item = function(item)
         local idx
         for i, entry in ipairs(Context.stack) do
            if entry == item then
               idx = i
               break
            end
         end
          local prefix = idx == 1 and "* " or "  "
          return prefix .. (item.title or "")
       end,
    }, function(choice)
       if not choice then
          return
       end
       local idx
       for i, entry in ipairs(Context.stack) do
          if entry == choice then
             idx = i
             break
          end
       end
       if not idx then
          return
       end
       if idx == 1 and showing_stack_entry(Context.stack[1]) then
          log.info("switched to context: " .. choice.title)
          return
       end
       confirm_leave_current(function()
          activate_idx(idx, "r")
          log.info("switched to context: " .. choice.title)
       end)
    end)
end

function Context.AddEditContextTitle()
   Context.current_title = vim.fn.getqflist({ title = 0 }).title or ""

   vim.ui.input({ prompt = "Quickfix title: ", default = Context.current_title }, function(title)
       if title == nil or title == "" then
          log.error("context must have title")
          return
       end
       vim.fn.setqflist({}, "r", { title = title })
       if Context.stack[1] then
          Context.stack[1].title = title
       end
       if Context.Options.trouble then
          require("trouble").refresh("qflist")
       end
       log.info("added/updated context title")
   end)
end

function Context.AddFlow()
   local info = vim.fn.getqflist({ context = 0 })
   local context = type(info.context) == "table" and info.context or {}

   vim.ui.input({ prompt = "Flow name: " }, function(name)
      if name == nil or name == "" then
         log.error("flow must have a name")
         return
      end
      local new_context = vim.deepcopy(context)
      local flows = new_context.flows
      if type(flows) ~= "table" then
         flows = {}
      end
      table.insert(flows, { title = name, items = {} })
      new_context.flows = flows
      write_qf_context(new_context)
      log.info("added flow: " .. name)
   end)
end

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

---@param arg1 any
---@param arg2 any
---@return number|nil, vim.quickfix.entry|nil
local function resolve_list_item(arg1, arg2)
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
   local idx = utils.find_qf_index(qflist, raw)
   return idx, idx and qflist[idx] or nil
end

---@param item vim.quickfix.entry
---@param idx integer
---@return number
local function item_ref_id(item, idx)
   local ud = item.user_data
   if type(ud) == "table" and ud.id ~= nil then
      return ud.id
   end
   return idx
end

---@class FlowEndpoint
---@field idx integer
---@field item vim.quickfix.entry
---@field id number

---@param arg1 any
---@param arg2 any
---@return FlowEndpoint[]|nil
local function resolve_flow_endpoints(arg1, arg2)
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
            table.insert(endpoints, { idx = i, item = item, id = item_ref_id(item, i) })
         end
      end
      if #endpoints == 0 then
         return nil
      end
      return endpoints
   end
   local idx, item = resolve_list_item(arg1, arg2)
   if not item or not idx then
      return nil
   end
   return { { idx = idx, item = item, id = item_ref_id(item, idx) } }
end

---@param flow ContextFlow
---@param id number
---@param idx integer
---@return boolean
local function flow_has_item(flow, id, idx)
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

---@param items number[][]
---@param from number
---@param to number
---@return boolean
local function connection_exists(items, from, to)
   for _, pair in ipairs(items) do
      if pair[1] == from and pair[2] == to then
         return true
      end
   end
   return false
end

---@param item vim.quickfix.entry
---@return string
local function format_flow_endpoint(item)
   local name = item.filename or ""
   local lnum = item.lnum or 0
   local text = item.text or ""
   if text ~= "" then
      return string.format("%s:%d %s", name, lnum, text)
   end
   return string.format("%s:%d", name, lnum)
end

---@param arg1 any
---@param arg2 any
function Context.AddItemToFlow(arg1, arg2)
   local from_trouble_ctx = type(arg1) == "table"
   local in_qf = vim.bo.filetype == "qf"
   local in_trouble = vim.bo.filetype == "trouble" or vim.w.trouble
   if not from_trouble_ctx and not in_qf and not in_trouble then
      log.error("AddItemToFlow must be run from the quickfix or trouble list")
      return
   end

   local endpoints = resolve_flow_endpoints(arg1, arg2)
   if not endpoints then
      log.error("no context reference under cursor")
      return
   end

   local info = vim.fn.getqflist({ context = 0 })
   local context = type(info.context) == "table" and vim.deepcopy(info.context) or {}
   local flows = context.flows
   if type(flows) ~= "table" or #flows == 0 then
      log.info("no flows available")
      return
   end

    ---@param flow ContextFlow
    ---@param pairs_to_add number[][]
    local function add_connections(flow, pairs_to_add)
       flow.items = type(flow.items) == "table" and flow.items or {}
       local added = 0
       local disconnected = 0
       for _, pair in ipairs(pairs_to_add) do
          if pair[1] == pair[2] or connection_exists(flow.items, pair[1], pair[2]) then
             -- skip
          elseif #flow.items > 0 and not flow_has_item(flow, pair[1], pair[1]) then
             disconnected = disconnected + 1
          else
             table.insert(flow.items, { pair[1], pair[2] })
             added = added + 1
          end
       end
       if added == 0 then
          if disconnected > 0 then
             log.error("source is not in flow: " .. (flow.title or ""))
          else
             log.info("connection already in flow: " .. (flow.title or ""))
          end
          return
       end
       write_qf_context(context)
       log.info("added connection to flow: " .. (flow.title or ""))
    end

   vim.ui.select(flows, {
      prompt = "Add connection to flow:",
      format_item = function(flow)
         return flow.title or ""
      end,
   }, function(choice)
      if not choice then
         return
      end
      if #endpoints >= 2 then
         local pairs_to_add = {}
         for i = 1, #endpoints - 1 do
            table.insert(pairs_to_add, { endpoints[i].id, endpoints[i + 1].id })
         end
         add_connections(choice, pairs_to_add)
         return
      end

      local source = endpoints[1]
      choice.items = type(choice.items) == "table" and choice.items or {}
      if #choice.items > 0 and not flow_has_item(choice, source.id, source.idx) then
         log.error("source is not in flow: " .. (choice.title or ""))
         return
      end
      local qflist = vim.fn.getqflist()
      local candidates = {}
      for i, item in ipairs(qflist) do
         if i ~= source.idx then
            table.insert(candidates, { idx = i, item = item, id = item_ref_id(item, i) })
         end
      end
      if #candidates == 0 then
         log.error("need another item to form a connection")
         return
      end
      vim.ui.select(candidates, {
         prompt = "Connect to:",
         format_item = function(entry)
            return format_flow_endpoint(entry.item)
         end,
      }, function(target)
         if not target then
            return
         end
         add_connections(choice, { { source.id, target.id } })
      end)
   end)
end

---@param arg1 any
---@param arg2 any
function Context.RemoveItemFromFlow(arg1, arg2)
   local from_trouble_ctx = type(arg1) == "table"
   local in_qf = vim.bo.filetype == "qf"
   local in_trouble = vim.bo.filetype == "trouble" or vim.w.trouble
   if not from_trouble_ctx and not in_qf and not in_trouble then
      log.error("RemoveItemFromFlow must be run from the quickfix or trouble list")
      return
   end

   local idx, item = resolve_list_item(arg1, arg2)
   if not item or not idx then
      log.error("no context reference under cursor")
      return
   end

   local info = vim.fn.getqflist({ context = 0 })
   local context = type(info.context) == "table" and vim.deepcopy(info.context) or {}
   local flows = context.flows
   if type(flows) ~= "table" or #flows == 0 then
      log.info("no flows available")
      return
   end

   local item_id = item_ref_id(item, idx)
   local containing = {}
   for _, flow in ipairs(flows) do
      if flow_has_item(flow, item_id, idx) then
         table.insert(containing, flow)
      end
   end

   if #containing == 0 then
      log.info("item is not in any flow")
      return
   end

   ---@param flow ContextFlow
   local function remove_from(flow)
      local kept = {}
      for _, pair in ipairs(flow.items) do
         if pair[1] ~= item_id and pair[1] ~= idx and pair[2] ~= item_id and pair[2] ~= idx then
            table.insert(kept, pair)
         end
      end
      flow.items = kept
      write_qf_context(context)
      log.info("removed item from flow: " .. (flow.title or ""))
   end

   if #containing == 1 then
      remove_from(containing[1])
      return
   end

    vim.ui.select(containing, {
       prompt = "Remove item from flow:",
       format_item = function(flow)
          return flow.title or ""
       end,
    }, function(choice)
       if not choice then
          return
       end
       remove_from(choice)
    end)
end

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
         local id = item_ref_id(item, i)
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

---@param flow ContextFlow
local function activate_flow(flow)
   local info = vim.fn.getqflist({ context = 0, title = 0, items = 0 })
   local ctx = type(info.context) == "table" and info.context or {}
   if not flow_parent then
      local parent_ctx = vim.deepcopy(ctx)
      parent_ctx.active_flow = nil
      flow_parent = {
         title = info.title or "",
         items = info.items or {},
         context = parent_ctx,
      }
   end

   local items = flow_to_qfitems(flow, flow_parent.items)
   if #items == 0 then
      log.info("flow has no items: " .. (flow.title or ""))
      if not is_flow_view(ctx) then
         flow_parent = nil
      end
      return
   end

   local view_ctx = vim.deepcopy(flow_parent.context)
   view_ctx.flows = ctx.flows or flow_parent.context.flows
   view_ctx.id = ctx.id or flow_parent.context.id
   view_ctx.active_flow = flow.title

   ---@type LoadedContext
   local loaded = {
      title = flow.title or "",
      items = items,
      context = view_ctx,
   }

   apply_loaded(loaded, "r", { keep_flow_parent = true })
   if vim.bo.filetype == "qf" then
      vim.wo.winbar = current_display_title()
   end
   log.info("loaded flow: " .. loaded.title)
end

---@param arg1 any
---@param arg2 any
function Context.ActivateItemFlow(arg1, arg2)
   local from_trouble_ctx = type(arg1) == "table"
   local in_qf = vim.bo.filetype == "qf"
   local in_trouble = vim.bo.filetype == "trouble" or vim.w.trouble
   if not from_trouble_ctx and not in_qf and not in_trouble then
      log.error("ActivateItemFlow must be run from the quickfix or trouble list")
      return
   end

   local idx, item = resolve_list_item(arg1, arg2)
   if not item or not idx then
      log.error("no context reference under cursor")
      return
   end

   local info = vim.fn.getqflist({ context = 0 })
   local context = type(info.context) == "table" and info.context or {}
   local flows = context.flows
   if type(flows) ~= "table" or #flows == 0 then
      log.info("no flows available")
      return
   end

   local item_id = item_ref_id(item, idx)
   local containing = {}
   for _, flow in ipairs(flows) do
      if flow_has_item(flow, item_id, idx) then
         table.insert(containing, flow)
      end
   end

   if #containing == 0 then
      log.info("item is not in any flow")
      return
   end

   if #containing == 1 then
      activate_flow(containing[1])
      return
   end

   vim.ui.select(containing, {
      prompt = "Activate flow:",
      format_item = function(flow)
         return flow.title or ""
      end,
   }, function(choice)
      if not choice then
         return
      end
      activate_flow(choice)
   end)
end

function Context.AddEditContextDescription()
   local context = vim.fn.getqflist({ context = 0 }).context
   local current_description = (type(context) == "table" and context.description) or ""
   ---@type ReferenceBuffer
   local referenceBuffer = {
      default = current_description,
      diagram_keymap = Context.Options.diagram.enabled and Context.Options.diagram.keymap or nil,
      diagram_enabled = Context.Options.diagram.enabled,
      diagram_snippets = Context.Options.diagram.enabled and Context.Options.diagram.snippets or nil,
   }

   buffer.open_reference_editor(referenceBuffer, function(description)
      if description == nil then
         return
      end
      local new_context = type(context) == "table" and vim.deepcopy(context) or {}
      new_context.description = description
      vim.fn.setqflist({}, "r", { context = new_context })
      if Context.Options.trouble then
         require("trouble").refresh("qflist")
      end
      log.info("added/updated context description")
    end)
end

function Context.SetContextType()
   local info = vim.fn.getqflist({ context = 0 })
    local context = type(info.context) == "table" and info.context or {}
    local current = list_type(context.type)

    vim.ui.select(STACK_TYPES, {
       prompt = "List type (current: " .. current .. "):",
    }, function(choice)
       if not choice then
          return
       end
       local typ = list_type(choice)
       local new_context = vim.deepcopy(context)
       new_context.type = typ
       vim.fn.setqflist({}, "r", { context = new_context })
       if vim.bo.filetype == "qf" then
          vim.wo.winbar = current_display_title()
       end
       if Context.Options and Context.Options.trouble then
          require("trouble").refresh("qflist")
       end
       log.info("set list type to " .. typ)
    end)
end

---@return boolean
function Context.SaveContext()
   if not Context.root then
      Context.root = vim.fs.root(0, ".git")
      if not Context.root then
         log.error("not inside a git repository")
         return false
      end
   end

   ---@type vim.fn.setqflist.what
   local live = vim.fn.getqflist({ context = 0, items = 0, title = 0 })
   local live_ctx = type(live.context) == "table" and live.context or {}
   local viewing_flow = is_flow_view(live_ctx)

   ---@type vim.fn.setqflist.what
   local info = live
   if viewing_flow then
      local parent_ctx
      if flow_parent and type(flow_parent.context) == "table" then
         parent_ctx = vim.deepcopy(flow_parent.context)
      else
         parent_ctx = vim.deepcopy(live_ctx)
      end
      parent_ctx.active_flow = nil
      parent_ctx.flows = live_ctx.flows or parent_ctx.flows or {}
      parent_ctx.id = live_ctx.id or parent_ctx.id or (Context.stack[1] and Context.stack[1].id)
      info = {
         title = (flow_parent and flow_parent.title ~= "" and flow_parent.title)
            or (Context.stack[1] and Context.stack[1].title)
            or "",
         items = flow_parent and flow_parent.items or {},
         context = parent_ctx,
      }
   end

   local title = info.title
   if title == "" or title == nil then
      log.error("set a title for context before saving")
      return false
   end

   local db_id = type(info.context) == "table" and info.context.id or nil

   -- A flow view is not its own list: write flows onto the parent ContextList only.
   if viewing_flow and db_id then
      local ok, err = pcall(
         sql.update_context,
         Context.root,
         { id = db_id, flows = live_ctx.flows or {} },
         {},
         {},
         title,
         nil
      )
      if not ok then
         log.error("failed to update context: " .. tostring(err))
         return false
      end
      if Context.stack[1] then
         Context.stack[1].id = db_id
         Context.stack[1].title = title
      end
      log.info("updated context: " .. title)
      return true
   end

   local previous_ok, previous_context = true, nil
   if db_id then
      previous_ok, previous_context = pcall(sql.load_list, Context.root, db_id)
      if not previous_ok then
         previous_context = nil
      end
   end

   ---@type boolean,boolean,ContextList
   local conv_ok, new, context = pcall(utils.qflist_to_context, info, previous_context)
   if not conv_ok then
      log.error("failed to build context: " .. tostring(context))
      return false
   end

   ---@type ContextItem, UpdateContextItem
   local new_items, updated_items =
      utils.qfitems_to_dbrows(info.items, previous_context and previous_context.items, Context.root)
   local deleted_ids = utils.deleted_item_ids(info.items, previous_context and previous_context.items)

   if new then
      local ok, new_id = pcall(sql.insert_context, Context.root, context, new_items)
      if not ok then
         log.error("failed to save context: " .. tostring(new_id))
         return false
      end
      local saved_ctx
      if viewing_flow then
         saved_ctx = vim.deepcopy(live_ctx)
         saved_ctx.id = new_id
         saved_ctx.flows = context.flows
         if flow_parent and flow_parent.context then
            flow_parent.context.id = new_id
         end
      else
         saved_ctx = type(info.context) == "table" and vim.deepcopy(info.context) or {}
         saved_ctx.id = new_id
      end
      vim.fn.setqflist({}, "r", { context = saved_ctx })
      if Context.stack[1] then
         Context.stack[1].id = new_id
         Context.stack[1].title = title
      else
         table.insert(Context.stack, 1, { id = new_id, title = title })
      end
      log.info("saved context: " .. title)
      return true
   elseif previous_ok then
      local ok, err = pcall(
         sql.update_context,
         Context.root,
         context,
         new_items,
         updated_items,
         previous_context and previous_context.title,
         deleted_ids
      )
      if not ok then
         log.error("failed to update context: " .. tostring(err))
         return false
      end
      if Context.stack[1] then
         Context.stack[1].id = db_id
         Context.stack[1].title = title
      end
      log.info("updated context: " .. title)
      return true
   else
      log.error("failed to load previous context: " .. tostring(previous_context))
      return false
   end
end

function Context.ConvertQFlist()
   if not Context.root then
      Context.root = vim.fs.root(0, ".git")
      if not Context.root then
         log.error("not inside a git repository")
         return
      end
   end

   local info = vim.fn.getqflist({ items = 0, title = 0, context = 0 })
   if not info.items or #info.items == 0 then
      log.error("quickfix list is empty")
      return
   end

   local converted, skipped = utils.qflist_to_context_items(info.items, Context.root)
   if #converted == 0 then
      log.error("no convertible quickfix entries")
      return
   end

   vim.ui.input({ prompt = "Quickfix title: ", default = info.title or "" }, function(title)
      if title == nil or title == "" then
         log.error("context must have title")
         return
      end
      vim.fn.setqflist({}, "r", { items = converted, title = title })
      if Context.Options.trouble then
         require("trouble").refresh("qflist")
      end
       if #Context.stack == 0 then
          adopt_current_qf()
       elseif Context.stack[1] then
          Context.stack[1].title = title
       end
      local msg = "converted " .. #converted .. " quickfix entries"
      if skipped > 0 then
         msg = msg .. " (" .. skipped .. " skipped)"
      end
      log.info(msg)
   end)
end

---@param line1? number
---@param line2? number
function Context.ShowReference(line1, line2)
   if not Context.root then
      Context.root = vim.fs.root(0, ".git")
      if not Context.root then
         log.error("not inside a git repository")
         return
      end
   end
   local bufnr = vim.api.nvim_get_current_buf()
   local start_line, end_line
   if line1 and line2 then
      start_line = line1
      end_line = line2
   end
   local filename = utils.get_file_path(bufnr, Context.root)
   local ok, items = pcall(sql.get_items_at_line, Context.root, filename, start_line, end_line)
   if not ok then
      log.error("failed to query references: " .. tostring(items))
      return
   end
   if not items or #items == 0 then
      log.info("no context references found at cursor")
      return
   end

    buffer.open_references_viewer(items, bufnr, function(item)
       activate_or_push(item.list_id, function(ok)
          if not ok then
             return
          end
          buffer.open_reference_editor({
             default = item.description,
             code = item.base_text,
             source_buf = bufnr,
             readonly = true,
             diagram_keymap = nil,
             diagram_enabled = Context.Options.diagram.enabled,
             on_move = function(on_done)
                transfer_reference(item, "move", on_done)
             end,
             on_copy = function(on_done)
                transfer_reference(item, "copy", on_done)
             end,
          }, function() end)
       end)
    end, {
      diagram_enabled = Context.Options.diagram.enabled,
      git_root = Context.root,
      on_activate = function(item)
         activate_or_push(item.list_id)
      end,
      on_move = function(item, on_done)
         transfer_reference(item, "move", on_done)
      end,
      on_copy = function(item, on_done)
         transfer_reference(item, "copy", on_done)
      end,
   })
end

function Context.StatuslineComponent()
   return {
      function()
         return current_display_title()
      end,
      cond = function()
         if not Context.Options.statusline then
            return false
         end
         local title = vim.fn.getqflist({ title = 0 }).title
         return title ~= nil and title ~= ""
      end,
   }
end

function Context.EditTroubleItemNote(ctx)
   if Context.Options.trouble then
      local raw_item = ctx and ctx.item and ctx.item.item
      if not raw_item then
         log.error("no quickfix reference under cursor")
         return
      end

      local qflist = vim.fn.getqflist()
      local idx = utils.find_qf_index(qflist, raw_item)
      if not idx then
         log.error("could not locate context reference")
         return
      end
      Context.EditReference(idx)
   else
      log.info("trouble not enabled")
   end
end

function Context.EditTroubleItemLines(ctx)
   if not (Context.Options and Context.Options.trouble) then
      log.info("trouble not enabled")
      return
   end
   if type(ctx) ~= "table" then
      log.error("no quickfix reference under cursor")
      return
   end

   local raw_item = ctx.item and ctx.item.item
   if not raw_item then
      log.error("no quickfix reference under cursor")
      return
   end

   local idx = utils.find_qf_index(vim.fn.getqflist(), raw_item)
   if not idx then
      log.error("could not locate context reference")
      return
   end
   edit_reference_lines(idx)
end

---@param idx number
local function delete_qf_index(idx)
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

---@param line1? number
function Context.DeleteReference(line1)
   if vim.bo.filetype ~= "qf" then
      log.error("DeleteReference must be run from the quickfix list")
      return
   end
   delete_qf_index(line1 or vim.fn.line("."))
end

---@param idx? number
---@param op "move"|"copy"
local function transfer_qf_reference(idx, op)
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
   transfer_reference(item, op)
end

---@param idx? number
function Context.MoveReference(idx)
   transfer_qf_reference(idx, "move")
end

---@param idx? number
function Context.CopyReference(idx)
   transfer_qf_reference(idx, "copy")
end

function Context.ToggleQfDiff()
   local on = require("nvim-context.qf").toggle()
   if on then
      log.info("qf jump diff on")
   else
      log.info("qf jump diff off")
   end
end

function Context.ToggleQfViewer()
   local on = require("nvim-context.qf").toggle_viewer()
   if on then
      log.info("qf reference viewer on")
   else
      log.info("qf reference viewer off")
   end
end

function Context.DeleteTroubleItem(ctx)
   if not (Context.Options and Context.Options.trouble) then
      log.info("trouble not enabled")
      return
   end

   local raw_item = ctx and ctx.item and ctx.item.item
   if not raw_item then
      log.error("no quickfix reference under cursor")
      return
   end

   local idx = utils.find_qf_index(vim.fn.getqflist(), raw_item)
   if not idx then
      log.error("could not locate context reference")
      return
   end
   delete_qf_index(idx)
end

return Context
