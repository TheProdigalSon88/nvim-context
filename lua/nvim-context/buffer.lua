local Buffer = {}

local log = require("nvim-context.log")

local hl_ns = vim.api.nvim_create_namespace("nvim_context_preview")

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
   vim.bo[buf].bufhidden = "wipe"
   vim.bo[buf].swapfile = false
   vim.bo[buf].filetype = "markdown"
   vim.api.nvim_buf_set_name(buf, "nvim-context-reference://" .. buf .. ".md")
   vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
   if opts.readonly then
      vim.bo[buf].modifiable = false
   end

   vim.cmd("botright " .. "vsplit")
   vim.api.nvim_win_set_buf(0, buf)
   local win = vim.api.nvim_get_current_win()

   if opts.diagram_enabled then
      vim.schedule(function()
         local ok, diagram = pcall(require, "diagram")
         if ok then
            diagram.render()
         end
      end)
   end

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
         if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
         end
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
      if vim.api.nvim_win_is_valid(win) then
         vim.api.nvim_win_close(win, true)
      end
   end, { buffer = buf, desc = "Close note editor without saving" })

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

---Opens a read-only split showing multiple references, newest at top.
---Each item is rendered as its own section with a human-readable timestamp
---heading, an optional description, and a fenced code block.
---@param items ContextItem[]  already sorted newest-first
---@param source_buf? number   source buffer (used for filetype detection)
---@param on_select? fun(item: ContextItem)  called when <CR> is pressed anywhere in a section
function Buffer.open_references_viewer(items, source_buf, on_select, opts)
   table.sort(items, function(a, b)
      return (a.timestamp or "") > (b.timestamp or "")
   end)
   local source_loaded = source_buf and vim.api.nvim_buf_is_loaded(source_buf)
   local lang = source_loaded and vim.bo[source_buf].filetype or ""

   local lines = {}
   local heading_lnums = {}

   for i, item in ipairs(items) do
      -- Section heading
      heading_lnums[i] = #lines + 1
      table.insert(lines, "### " .. format_timestamp(item.timestamp) .. " :: " .. item.list_title)
      table.insert(lines, "")

      -- Description (optional)
      local desc = item.description or ""
      if desc ~= "" then
         for line in (desc .. "\n"):gmatch("(.-)\n") do
            table.insert(lines, line)
         end
         table.insert(lines, "")
      end

      -- Fenced code block
      if item.base_text and item.base_text ~= "" then
         table.insert(lines, "```" .. lang)
         for line in (item.base_text .. "\n"):gmatch("(.-)\n") do
            table.insert(lines, line)
         end
         table.insert(lines, "```")
      end

      -- Separator between sections (not after the last one)
      if i < #items then
         table.insert(lines, "")
         table.insert(lines, "---")
         table.insert(lines, "")
      end
   end

   local buf = vim.api.nvim_create_buf(false, false)
   vim.bo[buf].buftype = "nofile"
   vim.bo[buf].bufhidden = "wipe"
   vim.bo[buf].swapfile = false
   vim.bo[buf].filetype = "markdown"
   vim.api.nvim_buf_set_name(buf, "nvim-context-references://" .. buf .. ".md")
   vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
   vim.bo[buf].modifiable = false

   vim.cmd("botright vsplit")
   vim.api.nvim_win_set_buf(0, buf)
   local win = vim.api.nvim_get_current_win()

   opts = opts or {}
   local rendered = false
   if opts.diagram_enabled then
      rendered = true
      vim.schedule(function()
         local ok, diagram = pcall(require, "diagram")
         if ok then
            diagram.render()
         end
      end)
   end

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
      if vim.api.nvim_win_is_valid(win) then
         vim.api.nvim_win_close(win, true)
      end
   end, { buffer = buf, desc = "Close references viewer" })

   vim.keymap.set("n", "<CR>", function()
      if not on_select then
         return
      end
      local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
      local selected_item
      for i = #heading_lnums, 1, -1 do
         if heading_lnums[i] <= cursor_line then
            selected_item = items[i]
            break
         end
      end
      if selected_item then
         local ok, err = pcall(on_select, selected_item)
         if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
         end
         if not ok then
            log.error("error selecting context: " .. tostring(err))
         end
      end
   end, { buffer = buf, desc = "Load context and view note" })
end

return Buffer
