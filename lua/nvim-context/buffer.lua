local Buffer = {}

local log = require("nvim-context.log")
local utils = require("nvim-context.utils")
local Diff = require("nvim-context.diff")

local viewer_ns = vim.api.nvim_create_namespace("nvim-context.viewer")

local CODE_DELIMITER = "## Associated Code"

---Lines inserted inside a ```mermaid fence for each diagram type.
local MERMAID_SNIPPETS = {
   flowchart = {
      "flowchart LR",
      "    A --> B",
   },
   sequenceDiagram = {
      "sequenceDiagram",
      "    participant A",
      "    A->>B: Message",
   },
   classDiagram = {
      "classDiagram",
      "    class Animal",
   },
   erDiagram = {
      "erDiagram",
      '    ENTITY1 ||--o{ ENTITY2 : "relation"',
   },
   stateDiagram = {
      "stateDiagram-v2",
      "    [*] --> State1",
   },
   gantt = {
      "gantt",
      "    title My Project",
      "    dateFormat YYYY-MM-DD",
      "    section Section",
      "    Task : 2024-01-01, 7d",
   },
}

---@param ts string|nil  ISO 8601 UTC timestamp e.g. "2024-06-10T14:32:00Z"
---@return string
local function format_timestamp(ts)
   if not ts or ts == "" then
      return "unknown"
   end
   -- "2024-06-10T14:32:00Z" -> "2024-06-10 14:32 UTC"
   local result = ts:gsub("T", " "):gsub(":%d%d Z$", " UTC"):gsub(":(%d%d)Z$", " UTC")
   return result
end

---@param lines string[]
---@param delimiter string
---@return number|nil
local function find_delimiter(lines, delimiter)
   for i, line in ipairs(lines) do
      if line == delimiter then
         return i
      end
   end
end

---Winbar action. Included only when the opener was given a callback for it.
---@class BufferAction
---@field key string
---@field label string
---@field desc? string
---@field callback fun()
---@field nowait? boolean
---@field silent? boolean

---@class BufferView
---@field lines string[]
---@field cursor? integer[]
---@field readonly? boolean
---@field writable? boolean
---@field modified? boolean
---@field written? boolean
---@field actions? BufferAction[]
---@field snippets? table<string, string>
---@field diagram_enabled? boolean
---@field close_desc? string
---@field on_write? fun(description: string)
---@field on_show? fun(session: BufferSession)
---@field on_hide? fun(session: BufferSession)
---@field on_discard? fun()

---@class BufferSession
---@field win integer
---@field buf integer
---@field views BufferView[]
---@field augroup integer
---@field keys string[]
---@field closing boolean
---@field applying boolean

---One context window and one buffer. Opens push a view; `q` pops.
---The winbar lists `view.actions` (move, copy, …) plus q — nothing else.
---@type BufferSession|nil
local session

local shutdown
local apply_view
local pop_view

---@param actions BufferAction[]|nil
---@param stacked boolean
---@return string
local function format_winbar(actions, stacked)
   local parts = {}
   for _, action in ipairs(actions or {}) do
      if action.label and action.label ~= "" then
         table.insert(parts, action.key .. ": " .. action.label)
      end
   end
   table.insert(parts, stacked and "q: back" or "q: close")
   return table.concat(parts, "    ")
end

---@param win integer|nil
local function clear_diagrams(win)
   if not win or not vim.api.nvim_win_is_valid(win) then
      return
   end
   pcall(vim.api.nvim_win_call, win, function()
      local ok, diagram = pcall(require, "diagram")
      if ok then
         diagram.clear()
      end
   end)
end

---@param win integer
---@param buf integer
---@param cursor integer[]|nil
local function place_cursor(win, buf, cursor)
   if not vim.api.nvim_win_is_valid(win) or not vim.api.nvim_buf_is_valid(buf) then
      return
   end
   local line_count = math.max(vim.api.nvim_buf_line_count(buf), 1)
   local wanted = cursor or { 1, 0 }
   local lnum = math.max(1, math.min(wanted[1] or 1, line_count))
   local col = math.max(0, wanted[2] or 0)
   pcall(vim.api.nvim_win_set_cursor, win, { lnum, col })
end

---@param s BufferSession
---@param view BufferView
local function capture_view(s, view)
   if s.views[#s.views] ~= view or not vim.api.nvim_buf_is_valid(s.buf) then
      return
   end
   if not vim.api.nvim_win_is_valid(s.win) or vim.api.nvim_win_get_buf(s.win) ~= s.buf then
      return
   end
   view.lines = vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)
   view.modified = vim.bo[s.buf].modified
   view.cursor = vim.api.nvim_win_get_cursor(s.win)
end

---@param s BufferSession
---@param view BufferView
local function hide_view(s, view)
   capture_view(s, view)
   if view.diagram_enabled then
      clear_diagrams(s.win)
   end
   if view.on_hide then
      local ok, err = pcall(view.on_hide, s)
      if not ok then
         log.error("context buffer: " .. tostring(err))
      end
   end
end

---@param s BufferSession
local function reset_maps(s)
   if vim.api.nvim_buf_is_valid(s.buf) then
      for _, key in ipairs(s.keys) do
         pcall(vim.keymap.del, "n", key, { buffer = s.buf })
      end
   end
   s.keys = {}
end

---@param s BufferSession
---@param key string
---@param rhs fun()
---@param map_opts? vim.keymap.set.Opts
local function bind_map(s, key, rhs, map_opts)
   map_opts = vim.tbl_extend("force", { buffer = s.buf }, map_opts or {})
   vim.keymap.set("n", key, rhs, map_opts)
   table.insert(s.keys, key)
end

local function session_alive()
   return session
      and not session.closing
      and vim.api.nvim_win_is_valid(session.win)
      and vim.api.nvim_buf_is_valid(session.buf)
end

local function create_session()
   vim.cmd("botright vsplit")
   local win = vim.api.nvim_get_current_win()
   local buf = vim.api.nvim_create_buf(false, false)
   vim.bo[buf].bufhidden = "hide"
   vim.bo[buf].swapfile = false
   vim.bo[buf].buflisted = false
   vim.api.nvim_buf_set_name(buf, "nvim-context://" .. buf .. ".md")
   vim.api.nvim_win_set_buf(win, buf)

   ---@type BufferSession
   local created = {
      win = win,
      buf = buf,
      views = {},
      augroup = vim.api.nvim_create_augroup("nvim-context-buffer-" .. win, { clear = true }),
      keys = {},
      closing = false,
      applying = false,
   }
   session = created

   vim.api.nvim_create_autocmd("WinClosed", {
      pattern = tostring(win),
      once = true,
      nested = true,
      callback = function()
         shutdown(created, false)
      end,
   })
   vim.api.nvim_create_autocmd("BufWinLeave", {
      buffer = buf,
      callback = function()
         if created.closing or created.applying then
            return
         end
         shutdown(created, false)
      end,
   })
   return created
end

---@param s BufferSession
---@param close_win boolean
function shutdown(s, close_win)
   if not s or s.closing then
      return
   end
   s.closing = true
   local views = s.views
   s.views = {}
   for i = #views, 1, -1 do
      local view = views[i]
      if i == #views then
         capture_view(s, view)
      end
      if view.diagram_enabled then
         clear_diagrams(s.win)
      end
      if view.on_hide then
         local ok, err = pcall(view.on_hide, s)
         if not ok then
            log.error("context buffer: " .. tostring(err))
         end
      end
      if not view.written and view.on_discard then
         local ok, err = pcall(view.on_discard)
         if not ok then
            log.error("context buffer: " .. tostring(err))
         end
      end
   end
   if session == s then
      session = nil
   end
   pcall(vim.api.nvim_del_augroup_by_id, s.augroup)
   if close_win and vim.api.nvim_win_is_valid(s.win) then
      pcall(vim.api.nvim_win_close, s.win, true)
   end
   local buf = s.buf
   vim.schedule(function()
      if buf and vim.api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) == 0 then
         pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
   end)
end

---@param s BufferSession
function apply_view(s)
   local view = s.views[#s.views]
   if not view or not vim.api.nvim_win_is_valid(s.win) or not vim.api.nvim_buf_is_valid(s.buf) then
      return
   end
   local buf, win = s.buf, s.win
   s.applying = true
   pcall(vim.api.nvim_clear_autocmds, { group = s.augroup })
   reset_maps(s)

   local lines = view.lines
   if not lines or #lines == 0 then
      lines = { "" }
      view.lines = lines
   end

   vim.bo[buf].modifiable = true
   vim.bo[buf].buftype = view.writable and "acwrite" or "nofile"
   if vim.bo[buf].filetype ~= "markdown" then
      vim.bo[buf].filetype = "markdown"
   end
   vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
   vim.bo[buf].modified = view.modified and true or false
   vim.bo[buf].modifiable = not view.readonly
   vim.api.nvim_buf_clear_namespace(buf, viewer_ns, 0, -1)

   for _, action in ipairs(view.actions or {}) do
      local map_opts = { desc = action.desc or action.label }
      if action.nowait then
         map_opts.nowait = true
      end
      if action.silent then
         map_opts.silent = true
      end
      bind_map(s, action.key, action.callback, map_opts)
   end

   local stacked = #s.views > 1
   bind_map(s, "q", function()
      pop_view(s, view)
   end, {
      desc = stacked and "Return to previous context buffer" or (view.close_desc or "Close context buffer"),
   })

   if view.snippets then
      for keymap_str, diagram_type in pairs(view.snippets) do
         local template = MERMAID_SNIPPETS[diagram_type]
         if template then
            bind_map(s, keymap_str, function()
               local row = vim.api.nvim_win_get_cursor(0)[1]
               local block = { "```mermaid" }
               vim.list_extend(block, template)
               table.insert(block, "```")
               vim.api.nvim_buf_set_lines(s.buf, row, row, false, block)
               vim.api.nvim_win_set_cursor(0, { row + 1, 0 })
               local ok, diagram = pcall(require, "diagram")
               if ok then
                  diagram.render()
               end
            end, { desc = "Insert " .. diagram_type .. " diagram" })
         end
      end
   end

   if view.writable and view.on_write then
      vim.api.nvim_create_autocmd("BufWriteCmd", {
         group = s.augroup,
         buffer = buf,
         callback = function()
            if s.closing or s.views[#s.views] ~= view then
               return
            end
            local reference_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
            local code_idx = find_delimiter(reference_lines, CODE_DELIMITER)
            if code_idx then
               reference_lines = vim.list_slice(reference_lines, 1, code_idx - 1)
            end
            local description = table.concat(reference_lines, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
            vim.bo[buf].modified = false
            view.written = true
            view.modified = false
            view.on_write(description)
            pop_view(s, view)
         end,
      })
   end

   place_cursor(win, buf, view.cursor)
   vim.wo[win].winbar = format_winbar(view.actions, stacked)
   s.applying = false
   if view.on_show then
      view.on_show(s)
   end
end

---Pop `expected` when it is the visible view. Omitting `expected` pops the top view.
---@param s BufferSession|nil
---@param expected? BufferView
function pop_view(s, expected)
   if not s or s.closing then
      return
   end
   if expected and s.views[#s.views] ~= expected then
      return
   end
   local top = table.remove(s.views)
   if top then
      hide_view(s, top)
      if not top.written and top.on_discard then
         local ok, err = pcall(top.on_discard)
         if not ok then
            log.error("context buffer: " .. tostring(err))
         end
      end
   end
   if s.closing then
      return
   end
   if #s.views == 0 then
      shutdown(s, true)
      return
   end
   if vim.api.nvim_win_is_valid(s.win) and vim.api.nvim_get_current_win() ~= s.win then
      pcall(vim.api.nvim_set_current_win, s.win)
   end
   apply_view(s)
end

---@param s BufferSession
---@param view BufferView
---@param cursor? integer[]
local function update_view(s, view, cursor)
   if s.closing or s.views[#s.views] ~= view then
      return
   end
   if not vim.api.nvim_buf_is_valid(s.buf) or not vim.api.nvim_win_is_valid(s.win) then
      return
   end
   local buf, win = s.buf, s.win
   local lines = view.lines
   if not lines or #lines == 0 then
      lines = { "" }
      view.lines = lines
   end
   vim.bo[buf].modifiable = true
   vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
   view.modified = false
   vim.bo[buf].modified = false
   vim.bo[buf].modifiable = not view.readonly
   if cursor then
      view.cursor = cursor
      place_cursor(win, buf, cursor)
   end
   vim.wo[win].winbar = format_winbar(view.actions, #s.views > 1)
end

---@param view BufferView
---@return BufferSession
local function open_view(view)
   view.cursor = view.cursor or { 1, 0 }
   if not session_alive() then
      if session and not session.closing then
         shutdown(session, false)
      end
      create_session()
   elseif vim.api.nvim_get_current_win() ~= session.win then
      pcall(vim.api.nvim_set_current_win, session.win)
   end
   local top = session.views[#session.views]
   if top then
      hide_view(session, top)
   end
   table.insert(session.views, view)
   apply_view(session)
   return session
end

---@param opts { default?: string, code?: string, source_buf?: number }
---@return string[]
local function build_reference_lines(opts)
   local lines = {}
   for line in ((opts.default or "") .. "\n"):gmatch("(.-)\n") do
      table.insert(lines, line)
   end
   if #lines == 0 then
      lines = { "" }
   end

   local source_buf = opts.source_buf
   local source_loaded = source_buf and vim.api.nvim_buf_is_loaded(source_buf)

   table.insert(lines, "")

   if opts.code ~= nil then
      local lang = source_loaded and vim.bo[source_buf].filetype or ""
      table.insert(lines, "")
      table.insert(lines, CODE_DELIMITER)
      table.insert(lines, "```" .. lang)
      for codeline in (opts.code .. "\n"):gmatch("(.-)\n") do
         table.insert(lines, codeline)
      end
      table.insert(lines, "```")
   end

   return lines
end

---Open a note on the shared context buffer.
---`m` / `c` are bound only when `opts.on_move` / `opts.on_copy` are passed.
---@param opts ReferenceBuffer
---@param callback function
function Buffer.open_reference_editor(opts, callback)
   callback = callback or function() end
   local lines = build_reference_lines(opts)
   local done = false
   local function finish(description)
      if done then
         return
      end
      done = true
      callback(description)
   end

   ---@type BufferView
   local view
   view = {
      lines = lines,
      readonly = opts.readonly and true or false,
      writable = not opts.readonly,
      diagram_enabled = opts.diagram_enabled and true or false,
      snippets = (not opts.readonly) and opts.diagram_snippets or nil,
      close_desc = "Close note editor without saving",
      actions = {},
      on_write = function(description)
         finish(description)
      end,
      on_discard = function()
         finish(nil)
      end,
      on_show = function(s)
         if not opts.diagram_enabled then
            return
         end
         vim.schedule(function()
            if s.closing or s.views[#s.views] ~= view or not vim.api.nvim_win_is_valid(s.win) then
               return
            end
            pcall(vim.api.nvim_win_call, s.win, function()
               local ok, diagram = pcall(require, "diagram")
               if ok then
                  diagram.render()
               end
            end)
         end)
      end,
   }

   if opts.on_move then
      table.insert(view.actions, {
         key = "m",
         label = "move",
         desc = "Move reference to another loaded context",
         nowait = true,
         silent = true,
         callback = function()
            opts.on_move(function(success)
               if success then
                  pop_view(session, view)
               end
            end)
         end,
      })
   end

   if opts.on_copy then
      table.insert(view.actions, {
         key = "c",
         label = "copy",
         desc = "Copy reference to another loaded context",
         nowait = true,
         silent = true,
         callback = function()
            opts.on_copy()
         end,
      })
   end

   open_view(view)
end

---@param item ContextItem
---@return integer, integer
local function item_range(item)
   local s = item.lnum or 0
   local e = item.end_lnum or s
   if e < s then
      s, e = e, s
   end
   return s, e
end

---True if `outer` strictly contains `inner` (equal ranges are not strict).
---@param outer ContextItem
---@param inner ContextItem
---@return boolean
local function strictly_contains(outer, inner)
   local os, oe = item_range(outer)
   local is, ie = item_range(inner)
   return os <= is and ie <= oe and (os < is or ie < oe)
end

---Innermost range first; later timestamp (then id) when ranges are incomparable.
---@param a ContextItem
---@param b ContextItem
---@return boolean
local function innermost_first(a, b)
   if strictly_contains(b, a) then
      return true
   end
   if strictly_contains(a, b) then
      return false
   end
   local ta, tb = a.timestamp or "", b.timestamp or ""
   if ta ~= tb then
      return ta > tb
   end
   return (a.id or 0) > (b.id or 0)
end

---Later timestamp first; later id when timestamps match.
---@param a ContextItem
---@param b ContextItem
---@return boolean
local function timestamp_latest_first(a, b)
   local ta, tb = a.timestamp or "", b.timestamp or ""
   if ta ~= tb then
      return ta > tb
   end
   return (a.id or 0) > (b.id or 0)
end

local SORT_MODES = {
   containment = innermost_first,
   timestamp = timestamp_latest_first,
}

local SORT_LABELS = {
   containment = "containment",
   timestamp = "timestamp (latest first)",
}

---@param items ContextItem[]
---@param lang string
---@return string[], integer[]
local function render_reference_sections(items, lang)
   local lines = {}
   local heading_lnums = {}

   for i, item in ipairs(items) do
      heading_lnums[i] = #lines + 1
      table.insert(lines, "### " .. format_timestamp(item.timestamp) .. " :: " .. item.list_title)
      table.insert(lines, "")

      local desc = item.description or ""
      if desc ~= "" then
         for line in (desc .. "\n"):gmatch("(.-)\n") do
            table.insert(lines, line)
         end
         table.insert(lines, "")
      end

      if item.base_text and item.base_text ~= "" then
         table.insert(lines, "```" .. lang)
         for line in (item.base_text .. "\n"):gmatch("(.-)\n") do
            table.insert(lines, line)
         end
         table.insert(lines, "```")
      end

      if i < #items then
         table.insert(lines, "")
         table.insert(lines, "---")
         table.insert(lines, "")
      end
   end

   return lines, heading_lnums
end

---@param heading_lnums integer[]
---@param items ContextItem[]
---@param cursor_line integer
---@return ContextItem|nil
local function item_at_line(heading_lnums, items, cursor_line)
   for i = #heading_lnums, 1, -1 do
      if heading_lnums[i] <= cursor_line then
         return items[i]
      end
   end
end

---@param heading_lnums integer[]
---@param lines string[]
---@param i integer
---@return integer, integer
local function section_bounds(heading_lnums, lines, i)
   local start = heading_lnums[i] or 1
   local finish = (heading_lnums[i + 1] or (#lines + 1)) - 1
   if finish < start then
      finish = start
   end
   while finish > start do
      local line = lines[finish]
      if line == "" or line == "---" then
         finish = finish - 1
      else
         break
      end
   end
   return start, finish
end

---@param source_buf? number
---@return integer|nil
local function find_source_win(source_buf)
   if not source_buf or not vim.api.nvim_buf_is_valid(source_buf) then
      return nil
   end
   for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == source_buf then
         return win
      end
   end
end

---Open the shared context buffer on a read-only multi-reference view.
---Winbar actions are enabled from the callbacks passed in: `s` is always bound;
---`a` / `m` / `c` / `<CR>` require `on_activate`, `on_move`, `on_copy`, and `on_select`.
---`q` pops back to the previous view, or closes the split when this is the last one.
---@param items ContextItem[]
---@param source_buf? number   source buffer (used for filetype detection)
---@param on_select? fun(item: ContextItem)  called when <CR> is pressed anywhere in a section
---@param opts? { diagram_enabled?: boolean, diagram_render_keymap?: string, git_root?: string, on_activate?: fun(item: ContextItem), on_move?: fun(item: ContextItem, on_done?: fun(success: boolean)), on_copy?: fun(item: ContextItem, on_done?: fun(success: boolean)) }
function Buffer.open_references_viewer(items, source_buf, on_select, opts)
   opts = opts or {}
   local sort_mode = "containment"
   table.sort(items, SORT_MODES[sort_mode])
   local source_loaded = source_buf and vim.api.nvim_buf_is_loaded(source_buf)
   local lang = source_loaded and vim.bo[source_buf].filetype or ""

   local lines, heading_lnums = render_reference_sections(items, lang)
   local git_root = opts.git_root
   local focused_item = nil
   local rendered = opts.diagram_enabled and true or false

   ---@type BufferSession|nil
   local current
   ---@type BufferView
   local view
   ---@type BufferAction
   local sort_action

   local function sort_label()
      return string.format("sort [%s]", SORT_LABELS[sort_mode] or sort_mode)
   end

   local function render_diagrams()
      if not rendered or not current or current.closing or not vim.api.nvim_win_is_valid(current.win) then
         return
      end
      local win = current.win
      vim.schedule(function()
         if not current or current.closing or current.views[#current.views] ~= view then
            return
         end
         if not vim.api.nvim_win_is_valid(win) then
            return
         end
         pcall(vim.api.nvim_win_call, win, function()
            local ok, diagram = pcall(require, "diagram")
            if ok then
               diagram.render()
            end
         end)
      end)
   end

   local function decorate_sections()
      if not current or not vim.api.nvim_buf_is_valid(current.buf) then
         return
      end
      local buf = current.buf
      vim.api.nvim_buf_clear_namespace(buf, viewer_ns, 0, -1)
      if not git_root then
         return
      end
      local viewer_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      for i, item in ipairs(items) do
         if utils.range_diff(git_root, item, { source_buf = source_buf }) then
            local start, finish = section_bounds(heading_lnums, viewer_lines, i)
            for l = start, finish do
               pcall(vim.api.nvim_buf_set_extmark, buf, viewer_ns, l - 1, 0, {
                  line_hl_group = "NvimContextChanged",
                  hl_eol = true,
               })
            end
         end
      end
   end

   local function clear_file_marks()
      Diff.clear(source_buf, Diff.ns)
   end

   ---@param item ContextItem|nil
   local function preview_item(item)
      clear_file_marks()
      if not item or not git_root then
         return
      end
      if not source_buf or not vim.api.nvim_buf_is_valid(source_buf) then
         return
      end
      local diff = utils.range_diff(git_root, item, { source_buf = source_buf })
      if not diff then
         return
      end
      local start_line = item.lnum or 1
      Diff.apply_range_marks(source_buf, Diff.ns, start_line, diff)
      local source_win = find_source_win(source_buf)
      if source_win then
         local line_count = vim.api.nvim_buf_line_count(source_buf)
         local lnum = math.max(1, math.min(start_line, line_count))
         pcall(vim.api.nvim_win_set_cursor, source_win, { lnum, 0 })
      end
   end

   local function preview_from_cursor()
      if not current or not vim.api.nvim_win_is_valid(current.win) then
         return
      end
      local cursor_line = vim.api.nvim_win_get_cursor(current.win)[1]
      local item = item_at_line(heading_lnums, items, cursor_line)
      if item == focused_item then
         return
      end
      focused_item = item
      preview_item(item)
   end

   local function refresh_diff()
      focused_item = nil
      decorate_sections()
      preview_from_cursor()
   end

   local function item_under_cursor()
      if not current or not vim.api.nvim_win_is_valid(current.win) then
         return
      end
      local cursor_line = vim.api.nvim_win_get_cursor(current.win)[1]
      return item_at_line(heading_lnums, items, cursor_line)
   end

   local function redraw(focused)
      if not current or current.closing or current.views[#current.views] ~= view then
         return
      end
      if #items == 0 then
         pop_view(current, view)
         return
      end
      lines, heading_lnums = render_reference_sections(items, lang)
      view.lines = lines
      sort_action.label = sort_label()
      local target_line = 1
      if focused then
         for i, item in ipairs(items) do
            if item == focused then
               target_line = heading_lnums[i]
               break
            end
         end
      end
      update_view(current, view, { target_line, 0 })
      if rendered then
         pcall(vim.api.nvim_win_call, current.win, function()
            local ok, diagram = pcall(require, "diagram")
            if ok then
               diagram.clear()
               diagram.render()
            end
         end)
      end
      refresh_diff()
   end

   ---@param selected ContextItem
   local function remove_viewer_item(selected)
      local next_focus
      for i, item in ipairs(items) do
         if item == selected then
            next_focus = items[i + 1] or items[i - 1]
            table.remove(items, i)
            break
         end
      end
      redraw(next_focus)
   end

   sort_action = {
      key = "s",
      label = sort_label(),
      desc = "Toggle sort (containment / timestamp)",
      callback = function()
         local focused = item_under_cursor()
         sort_mode = sort_mode == "containment" and "timestamp" or "containment"
         table.sort(items, SORT_MODES[sort_mode])
         redraw(focused)
      end,
   }

   ---@type BufferAction[]
   local actions = { sort_action }
   if opts.on_activate then
      table.insert(actions, {
         key = "a",
         label = "activate",
         desc = "Make section context active",
         callback = function()
            local selected_item = item_under_cursor()
            if not selected_item then
               return
            end
            local ok, err = pcall(opts.on_activate, selected_item)
            if not ok then
               log.error("error activating context: " .. tostring(err))
            end
         end,
      })
   end
   if opts.on_move then
      table.insert(actions, {
         key = "m",
         label = "move",
         desc = "Move reference to another loaded context",
         nowait = true,
         silent = true,
         callback = function()
            local selected_item = item_under_cursor()
            if not selected_item then
               return
            end
            local ok, err = pcall(opts.on_move, selected_item, function(success)
               if success then
                  remove_viewer_item(selected_item)
               end
            end)
            if not ok then
               log.error("error moving reference: " .. tostring(err))
            end
         end,
      })
   end
   if opts.on_copy then
      table.insert(actions, {
         key = "c",
         label = "copy",
         desc = "Copy reference to another loaded context",
         nowait = true,
         silent = true,
         callback = function()
            local selected_item = item_under_cursor()
            if not selected_item then
               return
            end
            local ok, err = pcall(opts.on_copy, selected_item)
            if not ok then
               log.error("error copying reference: " .. tostring(err))
            end
         end,
      })
   end
   if on_select then
      table.insert(actions, {
         key = "<CR>",
         label = "note",
         desc = "Load context and view note",
         callback = function()
            local selected_item = item_under_cursor()
            if not selected_item then
               return
            end
            local ok, err = pcall(on_select, selected_item)
            if not ok then
               log.error("error selecting context: " .. tostring(err))
            end
         end,
      })
   end

   view = {
      lines = lines,
      readonly = true,
      actions = actions,
      diagram_enabled = (opts.diagram_enabled or opts.diagram_render_keymap) and true or false,
      close_desc = "Close references viewer",
      on_show = function(s)
         current = s
         if opts.diagram_render_keymap then
            bind_map(s, opts.diagram_render_keymap, function()
               local ok, diagram = pcall(require, "diagram")
               if not ok then
                  return
               end
               if rendered then
                  diagram.clear()
                  rendered = false
               else
                  diagram.render()
                  rendered = true
               end
            end, { desc = "Toggle mermaid diagram rendering" })
         end
         vim.api.nvim_create_autocmd("CursorMoved", {
            group = s.augroup,
            buffer = s.buf,
            callback = function()
               preview_from_cursor()
            end,
         })
         vim.api.nvim_create_autocmd({ "WinLeave", "BufWinLeave" }, {
            group = s.augroup,
            buffer = s.buf,
            callback = function()
               focused_item = nil
               clear_file_marks()
            end,
         })
         render_diagrams()
         refresh_diff()
      end,
      on_hide = function()
         focused_item = nil
         clear_file_marks()
      end,
   }

   current = open_view(view)
end

---@class QfFollowState
---@field win integer|nil
---@field buf integer|nil
---@field on_close? fun()
---@field diagram_enabled? boolean

---@type QfFollowState
local follow = {}
local follow_closing = false

local function follow_win_valid()
   return follow.win and vim.api.nvim_win_is_valid(follow.win)
end

local function follow_buf_valid()
   return follow.buf and vim.api.nvim_buf_is_valid(follow.buf)
end

---@param opts? { user?: boolean }
function Buffer.close_qf_follow(opts)
   opts = opts or {}
   local on_close = follow.on_close
   local win = follow.win
   local buf = follow.buf
   follow = {}
   if opts.user and on_close then
      on_close()
   end
   follow_closing = true
   if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
   end
   if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
   end
   follow_closing = false
end

---@return integer|nil
local function find_follow_split_win()
   local function usable(win)
      if follow.win and win == follow.win then
         return false
      end
      if vim.w[win].trouble or vim.w[win].trouble_preview then
         return false
      end
      local buf = vim.api.nvim_win_get_buf(win)
      return vim.bo[buf].buftype == ""
   end

   local current = vim.api.nvim_get_current_win()
   if usable(current) then
      return current
   end
   for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if usable(win) then
         return win
      end
   end
   if follow.win and current == follow.win then
      return nil
   end
   return current
end

local function ensure_follow_buf()
   if follow_buf_valid() then
      return follow.buf
   end
   local buf = vim.api.nvim_create_buf(false, true)
   vim.bo[buf].buftype = "nofile"
   vim.bo[buf].bufhidden = "wipe"
   vim.bo[buf].swapfile = false
   vim.bo[buf].filetype = "markdown"
   vim.api.nvim_buf_set_name(buf, "nvim-context-qf-follow://reference.md")
   vim.keymap.set("n", "q", function()
      Buffer.close_qf_follow({ user = true })
   end, { buffer = buf, desc = "Close reference viewer" })
   follow.buf = buf
   return buf
end

local function ensure_follow_win(buf)
   if follow_win_valid() then
      if vim.api.nvim_win_get_buf(follow.win) ~= buf then
         pcall(function()
            vim.wo[follow.win].winfixbuf = false
         end)
         vim.api.nvim_win_set_buf(follow.win, buf)
      end
      pcall(function()
         vim.wo[follow.win].winfixbuf = true
      end)
      return follow.win
   end

   local split_win = find_follow_split_win()
   if not split_win then
      return nil
   end
   local new_win
   vim.api.nvim_win_call(split_win, function()
      vim.cmd("botright vsplit")
      new_win = vim.api.nvim_get_current_win()
   end)
   if not new_win or not vim.api.nvim_win_is_valid(new_win) then
      return nil
   end
   vim.api.nvim_win_set_buf(new_win, buf)
   vim.wo[new_win].winbar = "q: close"
   pcall(function()
      vim.wo[new_win].winfixbuf = true
   end)
   follow.win = new_win
   vim.api.nvim_create_autocmd("WinClosed", {
      pattern = tostring(new_win),
      once = true,
      nested = true,
      callback = function()
         if follow_closing or follow.win ~= new_win then
            return
         end
         Buffer.close_qf_follow({ user = true })
      end,
   })
   return new_win
end

local function render_follow_diagrams()
   if not follow.diagram_enabled or not follow_win_valid() then
      return
   end
   vim.schedule(function()
      if not follow_win_valid() then
         return
      end
      vim.api.nvim_win_call(follow.win, function()
         local ok, diagram = pcall(require, "diagram")
         if ok then
            diagram.clear()
            diagram.render()
         end
      end)
   end)
end

---Show the current quickfix context item in a persistent readonly split.
---Does not steal focus. `winfixbuf` keeps `:cnext` / `:cprev` from replacing
---the window; contents update in place as the qf index changes.
---@param item vim.quickfix.entry
---@param opts? { diagram_enabled?: boolean, on_close?: fun() }
function Buffer.show_qf_follow(item, opts)
   opts = opts or {}
   follow.on_close = opts.on_close
   follow.diagram_enabled = opts.diagram_enabled

   local user_data = type(item.user_data) == "table" and item.user_data or {}
   local buf = ensure_follow_buf()
   local lines = build_reference_lines({
      default = user_data.description or "",
      code = user_data.base_text,
      source_buf = item.bufnr,
   })
   vim.bo[buf].modifiable = true
   vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
   vim.bo[buf].modifiable = false
   vim.bo[buf].modified = false

   if not ensure_follow_win(buf) then
      return
   end
   render_follow_diagrams()
end

return Buffer
