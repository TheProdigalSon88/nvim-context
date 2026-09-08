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

---@class ContextBufferFrame
---@field buf integer
---@field cursor integer[]
---@field winbar string
---@field on_show? fun()

---@type table<integer, ContextBufferFrame[]>
local stacks = {}

---@param buf integer|nil
local function stack_wipe(buf)
   if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
   end
end

---@param win integer
local function stack_cleanup(win)
   local stack = stacks[win]
   stacks[win] = nil
   if not stack then
      return
   end
   for _, frame in ipairs(stack) do
      stack_wipe(frame.buf)
   end
end

---@param win integer
local function stack_ensure_cleanup(win)
   vim.api.nvim_create_autocmd("WinClosed", {
      pattern = tostring(win),
      once = true,
      nested = true,
      callback = function()
         stack_cleanup(win)
      end,
   })
end

---@param win integer
local function stack_save_top(win)
   local stack = stacks[win]
   if not stack or #stack == 0 or not vim.api.nvim_win_is_valid(win) then
      return
   end
   local top = stack[#stack]
   top.cursor = vim.api.nvim_win_get_cursor(win)
   top.winbar = vim.wo[win].winbar or ""
end

---@param win integer
---@param frame ContextBufferFrame
local function stack_show(win, frame)
   if not vim.api.nvim_win_is_valid(win) or not vim.api.nvim_buf_is_valid(frame.buf) then
      return
   end
   vim.api.nvim_win_set_buf(win, frame.buf)
   local line_count = vim.api.nvim_buf_line_count(frame.buf)
   local cursor = frame.cursor or { 1, 0 }
   local lnum = math.max(1, math.min(cursor[1] or 1, line_count))
   local col = math.max(0, cursor[2] or 0)
   pcall(vim.api.nvim_win_set_cursor, win, { lnum, col })
   vim.wo[win].winbar = frame.winbar or ""
   if frame.on_show then
      frame.on_show()
   end
end

---@param win integer
local function stack_pop(win)
   if not vim.api.nvim_win_is_valid(win) then
      stack_cleanup(win)
      return
   end
   local stack = stacks[win]
   if not stack or #stack == 0 then
      return
   end
   local top = table.remove(stack)
   if #stack == 0 then
      stacks[win] = nil
      if vim.api.nvim_win_is_valid(win) then
         vim.api.nvim_win_close(win, true)
      end
      stack_wipe(top.buf)
      return
   end
   local prev = stack[#stack]
   if vim.api.nvim_buf_is_valid(prev.buf) then
      stack_show(win, prev)
   else
      stack_wipe(top.buf)
      stack_pop(win)
      return
   end
   stack_wipe(top.buf)
end

---@param buf integer
---@param opts? { on_show?: fun() }
---@return integer
local function present_buffer(buf, opts)
   opts = opts or {}
   local win = vim.api.nvim_get_current_win()
   local stack = stacks[win]
   if stack and #stack > 0 then
      stack_save_top(win)
      vim.api.nvim_win_set_buf(win, buf)
      vim.wo[win].winbar = ""
      table.insert(stack, {
         buf = buf,
         cursor = { 1, 0 },
         winbar = "",
         on_show = opts.on_show,
      })
      return win
   end

   vim.cmd("botright vsplit")
   win = vim.api.nvim_get_current_win()
   vim.api.nvim_win_set_buf(win, buf)
   stacks[win] = {
      {
         buf = buf,
         cursor = { 1, 0 },
         winbar = "",
         on_show = opts.on_show,
      },
   }
   stack_ensure_cleanup(win)
   return win
end

---@param opts ReferenceBuffer
---@param callback function
function Buffer.open_reference_editor(opts, callback)
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

   local buf = vim.api.nvim_create_buf(false, false)
   vim.bo[buf].buftype = "acwrite"
   vim.bo[buf].bufhidden = "hide"
   vim.bo[buf].swapfile = false
   vim.bo[buf].filetype = "markdown"
   vim.api.nvim_buf_set_name(buf, "nvim-context-reference://" .. buf .. ".md")
   vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
   if opts.readonly then
      vim.bo[buf].modifiable = false
   end

   local function render_diagrams()
      if not opts.diagram_enabled then
         return
      end
      vim.schedule(function()
         local ok, diagram = pcall(require, "diagram")
         if ok then
            diagram.render()
         end
      end)
   end

   local win = present_buffer(buf, {
      on_show = opts.diagram_enabled and render_diagrams or nil,
   })
   local stacked = stacks[win] and #stacks[win] > 1
   if stacked then
      vim.wo[win].winbar = "q: back"
   end
   render_diagrams()

   local done = false
   local function finish(description, labels)
      if done then
         return
      end
      done = true
      callback(description, labels)
   end

   vim.api.nvim_create_autocmd("BufWriteCmd", {
      buffer = buf,
      callback = function()
         local reference_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

         local code_idx = find_delimiter(reference_lines, CODE_DELIMITER)
         if code_idx then
            reference_lines = vim.list_slice(reference_lines, 1, code_idx - 1)
         end

         local description = table.concat(reference_lines, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
         vim.bo[buf].modified = false
         finish(description)
         stack_pop(win)
      end,
   })

   vim.api.nvim_create_autocmd("BufWinLeave", {
      buffer = buf,
      once = true,
      callback = function()
         finish(nil)
      end,
   })

   vim.keymap.set("n", "q", function()
      stack_pop(win)
   end, {
      buffer = buf,
      desc = stacked and "Return to previous context buffer" or "Close note editor without saving",
   })

   if opts.diagram_snippets and not opts.readonly then
      for keymap_str, diagram_type in pairs(opts.diagram_snippets) do
         local template = MERMAID_SNIPPETS[diagram_type]
         if template then
            vim.keymap.set("n", keymap_str, function()
               local row = vim.api.nvim_win_get_cursor(0)[1]
               local block = { "```mermaid" }
               vim.list_extend(block, template)
               table.insert(block, "```")
               vim.api.nvim_buf_set_lines(buf, row, row, false, block)
               vim.api.nvim_win_set_cursor(0, { row + 1, 0 })
               local ok, diagram = pcall(require, "diagram")
               if ok then
                  diagram.render()
               end
            end, { buffer = buf, desc = "Insert " .. diagram_type .. " diagram" })
         end
      end
   end
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

---@param sort_mode string
---@return string
local function sort_winbar(sort_mode)
   return string.format("s: sort [%s]    <CR>: load    q: close", SORT_LABELS[sort_mode] or sort_mode)
end

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

---Opens a read-only split showing multiple references.
---Default sort is containment (innermost range at top); `s` toggles to
---timestamp latest-first. `<CR>` stacks the reference editor in this window;
---`q` pops back (or closes when this is the last frame). Each item is
---rendered as its own section with a human-readable timestamp heading, an
---optional description, and a fenced code block.
---@param items ContextItem[]
---@param source_buf? number   source buffer (used for filetype detection)
---@param on_select? fun(item: ContextItem)  called when <CR> is pressed anywhere in a section
---@param opts? { diagram_enabled?: boolean, diagram_render_keymap?: string, git_root?: string }
function Buffer.open_references_viewer(items, source_buf, on_select, opts)
   local sort_mode = "containment"
   table.sort(items, SORT_MODES[sort_mode])
   local source_loaded = source_buf and vim.api.nvim_buf_is_loaded(source_buf)
   local lang = source_loaded and vim.bo[source_buf].filetype or ""

   local lines, heading_lnums = render_reference_sections(items, lang)

   local buf = vim.api.nvim_create_buf(false, false)
   vim.bo[buf].buftype = "nofile"
   vim.bo[buf].bufhidden = "hide"
   vim.bo[buf].swapfile = false
   vim.bo[buf].filetype = "markdown"
   vim.api.nvim_buf_set_name(buf, "nvim-context-references://" .. buf .. ".md")
   vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
   vim.bo[buf].modifiable = false

    opts = opts or {}
   local git_root = opts.git_root
   local focused_item = nil
   local rendered = false
   local function render_diagrams()
      if not rendered then
         return
      end
      vim.schedule(function()
         local ok, diagram = pcall(require, "diagram")
         if ok then
            diagram.render()
         end
      end)
   end

   local function decorate_sections()
      if not vim.api.nvim_buf_is_valid(buf) then
         return
      end
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

   local win
   local function preview_from_cursor()
      local cursor_line = 1
      if win and vim.api.nvim_win_is_valid(win) then
         cursor_line = vim.api.nvim_win_get_cursor(win)[1]
      end
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

   win = present_buffer(buf, {
      on_show = function()
         render_diagrams()
         refresh_diff()
      end,
   })
   vim.wo[win].winbar = sort_winbar(sort_mode)
   if opts.diagram_enabled then
      rendered = true
      render_diagrams()
   end
   refresh_diff()

   vim.api.nvim_create_autocmd("CursorMoved", {
      buffer = buf,
      callback = function()
         preview_from_cursor()
      end,
   })
   vim.api.nvim_create_autocmd({ "WinLeave", "BufWinLeave" }, {
      buffer = buf,
      callback = function()
         focused_item = nil
         clear_file_marks()
      end,
   })

   if opts.diagram_render_keymap then
      vim.keymap.set("n", opts.diagram_render_keymap, function()
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
      end, { buffer = buf, desc = "Toggle mermaid diagram rendering" })
   end

   vim.keymap.set("n", "q", function()
      stack_pop(win)
   end, { buffer = buf, desc = "Close references viewer" })

   vim.keymap.set("n", "s", function()
      local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
      local focused = item_at_line(heading_lnums, items, cursor_line)
      sort_mode = sort_mode == "containment" and "timestamp" or "containment"
      table.sort(items, SORT_MODES[sort_mode])
      local new_lines
      new_lines, heading_lnums = render_reference_sections(items, lang)
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
      vim.bo[buf].modifiable = false
      if vim.api.nvim_win_is_valid(win) then
         vim.wo[win].winbar = sort_winbar(sort_mode)
      end

      local target_line = 1
      if focused then
         for i, item in ipairs(items) do
            if item == focused then
               target_line = heading_lnums[i]
               break
            end
         end
      end
      if vim.api.nvim_win_is_valid(win) then
         vim.api.nvim_win_set_cursor(win, { target_line, 0 })
      end

      if rendered then
         local ok, diagram = pcall(require, "diagram")
         if ok then
            diagram.clear()
            diagram.render()
         end
      end
      refresh_diff()
   end, { buffer = buf, desc = "Toggle sort (containment / timestamp)" })

   vim.keymap.set("n", "<CR>", function()
      if not on_select then
         return
      end
      local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
      local selected_item = item_at_line(heading_lnums, items, cursor_line)
      if selected_item then
         local ok, err = pcall(on_select, selected_item)
         if not ok then
            log.error("error selecting context: " .. tostring(err))
         end
      end
   end, { buffer = buf, desc = "Load context and view note" })
end

return Buffer
