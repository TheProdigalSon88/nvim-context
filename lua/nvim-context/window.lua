local Window = {}

--- Define highlight groups for the creation form.
local function ensure_highlights()
  local function hi(name, opts)
    local existing = vim.api.nvim_get_hl(0, { name = name })
    if vim.tbl_isempty(existing) then
      vim.api.nvim_set_hl(0, name, opts)
    end
  end
  hi("NvimContextLabel", { link = "Title" })
  hi("NvimContextSep", { link = "FloatBorder" })
  hi("NvimContextPlaceholder", { link = "Comment" })
  hi("NvimContextHintKey", { link = "Special" })
  hi("NvimContextHintText", { link = "Comment" })
end

--- Show or hide placeholder text on a given line when it is empty.
---@param buf number
---@param ns number
---@param line number 0-indexed buffer line
---@param text string placeholder content
---@param mark_id_key string key to store extmark id
---@param state table mutable table for storing extmark ids
local function refresh_placeholder(buf, ns, line, text, mark_id_key, state)
  local content = vim.api.nvim_buf_get_lines(buf, line, line + 1, false)[1] or ""
  if content == "" then
    if not state[mark_id_key] then
      state[mark_id_key] = vim.api.nvim_buf_set_extmark(buf, ns, line, 0, {
        virt_text = { { text, "NvimContextPlaceholder" } },
        virt_text_pos = "overlay",
      })
    end
  else
    if state[mark_id_key] then
      vim.api.nvim_buf_del_extmark(buf, ns, state[mark_id_key])
      state[mark_id_key] = nil
    end
  end
end

function Window.open_floating_creation(title, on_submit)
  ensure_highlights()

  local width = math.max(52, math.floor(vim.o.columns / 3))
  local inner = width - 4 -- usable width inside padding
  local sep = "  " .. string.rep("─", inner) .. "  "

  -- Buffer layout (0-indexed):
  --  0  ""        <- label "Name" (extmark overlay)
  --  1  ""        <- editable name input
  --  2  sep       <- separator
  --  3  ""        <- label "Description" (extmark overlay)
  --  4  ""        <- editable description line 1
  --  5  ""        <- editable description line 2
  --  6  ""        <- editable description line 3
  --  7  sep       <- separator
  --  8  ""        <- hint keys (extmark overlay)
  local template = { "", "", sep, "", "", "", "", sep, "" }
  local height = #template

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("filetype", "nvim-context", { buf = buf })
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_set_option_value("undolevels", -1, { buf = buf })

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, template)

  local row = math.floor((vim.o.lines - height) / 2 - 1)
  local col = math.floor((vim.o.columns - width) / 2 - 1)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "center",
  })

  vim.api.nvim_set_option_value(
    "winhighlight",
    "NormalFloat:Normal,FloatBorder:Special,FloatTitle:Title",
    { win = win }
  )

  -- ── Extmark decorations ──────────────────────────────────────────────
  local ns = vim.api.nvim_create_namespace("nvim_context_creation")

  -- Field labels
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
    virt_text = { { "  Name", "NvimContextLabel" } },
    virt_text_pos = "overlay",
  })
  vim.api.nvim_buf_set_extmark(buf, ns, 3, 0, {
    virt_text = { { "  Description", "NvimContextLabel" } },
    virt_text_pos = "overlay",
  })

  -- Separator line highlights
  vim.api.nvim_buf_set_extmark(buf, ns, 2, 0, { line_hl_group = "NvimContextSep" })
  vim.api.nvim_buf_set_extmark(buf, ns, 7, 0, { line_hl_group = "NvimContextSep" })

  -- Hint bar
  vim.api.nvim_buf_set_extmark(buf, ns, 8, 0, {
    virt_text = {
      { "  <Tab> ", "NvimContextHintKey" },
      { "Next field", "NvimContextHintText" },
      { "  ", "Normal" },
      { "<CR> ", "NvimContextHintKey" },
      { "Submit", "NvimContextHintText" },
      { "  ", "Normal" },
      { "q / <Esc> ", "NvimContextHintKey" },
      { "Cancel", "NvimContextHintText" },
    },
    virt_text_pos = "overlay",
  })

  -- ── Placeholder text ─────────────────────────────────────────────────
  local ph = {} -- mutable state for placeholder extmark ids
  local NAME_LINE = 1
  local DESC_START = 4
  local DESC_END = 6

  local function update_placeholders()
    refresh_placeholder(buf, ns, NAME_LINE, "  letters, _ or - only", "name", ph)
    refresh_placeholder(buf, ns, DESC_START, "  What is this context about?", "desc", ph)
  end
  update_placeholders()

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = buf,
    callback = update_placeholders,
  })

  -- ── Cursor locking ───────────────────────────────────────────────────
  -- Only lines 1, 4, 5, 6 are editable (name input + description rows)
  local editable = { [NAME_LINE] = true, [DESC_START] = true, [5] = true, [DESC_END] = true }
  local last_editable_line = NAME_LINE

  local function clamp_cursor()
    if not vim.api.nvim_win_is_valid(win) then
      return
    end
    local cur = vim.api.nvim_win_get_cursor(win)[1] - 1 -- 0-indexed
    if editable[cur] then
      last_editable_line = cur
      return
    end
    -- Find nearest editable line, respecting direction of travel
    if cur < NAME_LINE then
      vim.api.nvim_win_set_cursor(win, { NAME_LINE + 1, 0 })
    elseif cur >= 2 and cur <= 3 then
      -- Between fields (separator or description label): decide by previous position
      if last_editable_line and last_editable_line >= DESC_START then
        -- Came from description going up -> land on name
        vim.api.nvim_win_set_cursor(win, { NAME_LINE + 1, 0 })
      else
        -- Came from name going down -> land on description
        vim.api.nvim_win_set_cursor(win, { DESC_START + 1, 0 })
      end
    elseif cur > DESC_END then
      vim.api.nvim_win_set_cursor(win, { DESC_END + 1, 0 })
    end
  end

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    buffer = buf,
    callback = clamp_cursor,
  })

  -- Start on the name field
  vim.api.nvim_win_set_cursor(win, { NAME_LINE + 1, 0 })

  -- ── Autocmds ─────────────────────────────────────────────────────────
  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
    buffer = buf,
    callback = function()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end,
  })

  vim.api.nvim_create_autocmd("VimResized", {
    buffer = buf,
    callback = function()
      if not vim.api.nvim_win_is_valid(win) then
        return
      end
      local new_w = math.max(52, math.floor(vim.o.columns / 3))
      local new_h = height
      vim.api.nvim_win_set_config(win, {
        width = new_w,
        height = new_h,
        row = math.floor((vim.o.lines - new_h) / 2 - 1),
        col = math.floor((vim.o.columns - new_w) / 2 - 1),
      })
    end,
  })

  -- ── Keymaps ──────────────────────────────────────────────────────────
  vim.keymap.set({ "n", "i" }, "<cr>", function()
    local all = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    local name = vim.trim(all[NAME_LINE + 1] or "")

    local desc_parts = {}
    for i = DESC_START + 1, DESC_END + 1 do
      local ln = all[i]
      if ln and ln ~= "" then
        table.insert(desc_parts, ln)
      end
    end
    local description = vim.trim(table.concat(desc_parts, "\n"))

    if name == "" then
      vim.notify("Name cannot be empty", vim.log.levels.WARN)
      return
    end
    if not name:match("^[%a_-]+$") then
      vim.notify("Name must contain only letters, _ or -", vim.log.levels.WARN)
      return
    end

    vim.api.nvim_win_close(win, true)
    if on_submit then
      on_submit(name, description)
    end
  end, { buffer = buf, desc = "Submit context" })

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  -- Field cycling
  vim.keymap.set({ "n", "i" }, "<tab>", function()
    local cur = vim.api.nvim_win_get_cursor(win)[1] - 1 -- 0-indexed
    if cur == NAME_LINE then
      vim.api.nvim_win_set_cursor(win, { DESC_START + 1, 0 })
    else
      vim.api.nvim_win_set_cursor(win, { NAME_LINE + 1, 0 })
    end
  end, { buffer = buf, desc = "Next field" })

  vim.keymap.set({ "n", "i" }, "<s-tab>", function()
    local cur = vim.api.nvim_win_get_cursor(win)[1] - 1 -- 0-indexed
    if cur >= DESC_START then
      vim.api.nvim_win_set_cursor(win, { NAME_LINE + 1, 0 })
    else
      vim.api.nvim_win_set_cursor(win, { DESC_START + 1, 0 })
    end
  end, { buffer = buf, desc = "Previous field" })

  vim.keymap.set("n", "q", close, { buffer = buf, desc = "Close" })
  vim.keymap.set("n", "<c-c>", close, { buffer = buf, desc = "Close" })
  vim.keymap.set("n", "<esc>", close, { buffer = buf, desc = "Close" })
end

function Window.open_floating_selection(title, items)
  local width = math.floor(vim.o.columns / 3)
  local height = math.floor(vim.o.lines / 3)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("filetype", "nvim-context", { buf = buf })
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_set_option_value("undolevels", -1, { buf = buf })

  local row = math.floor((vim.o.lines - height) / 2 - 1)
  local col = math.floor((vim.o.columns - width) / 2 - 1)

  local lines = {}
  local keymap_actions = {}

  if items and #items > 0 then
    for i, item in ipairs(items) do
      table.insert(lines, string.format("[%d] %s", i, item.label))
      keymap_actions[tostring(i)] = item.action
    end
    table.insert(lines, "")
    table.insert(lines, "Press number to select, 'q' to close")
  else
    table.insert(lines, "Press 'q' to close")
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  local win_opts = {
    relative = "editor",
    width = width,
    height = math.max(height, #lines + 2),
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
  }

  local win = vim.api.nvim_open_win(buf, true, win_opts)

  vim.api.nvim_set_option_value(
    "winhighlight",
    "NormalFloat:Normal,FloatBorder:Special,FloatTitle:Title",
    { win = win }
  )

  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
    buffer = buf,
    callback = function()
      vim.api.nvim_win_close(win, true)
    end,
  })

  vim.api.nvim_create_autocmd("VimResized", {
    buffer = buf,
    callback = function()
      local new_width = math.floor(vim.o.columns / 3)
      local new_height = math.floor(vim.o.lines / 3)
      local new_row = math.floor((vim.o.lines - new_height) / 2 - 1)
      local new_col = math.floor((vim.o.columns - new_width) / 2 - 1)
      vim.api.nvim_win_set_config(win, {
        width = new_width,
        height = new_height,
        row = new_row,
        col = new_col,
      })
    end,
  })

  for key, action in pairs(keymap_actions) do
    vim.keymap.set("n", key, function()
      vim.api.nvim_win_close(win, true)
      action()
    end, { buffer = buf, desc = "Select " .. key })
  end

  if items and #items > 0 then
    vim.keymap.set("n", "<cr>", function()
      local cursor_line = vim.api.nvim_win_get_cursor(win)[1]
      local action = keymap_actions[tostring(cursor_line)]
      if action then
        vim.api.nvim_win_close(win, true)
        action()
      end
    end, { buffer = buf, desc = "Select current" })
  end

  vim.keymap.set("n", "q", vim.cmd.close, { buffer = buf, desc = "Close" })
  vim.keymap.set("n", "<c-c>", vim.cmd.close, { buffer = buf, desc = "Close" })
  vim.keymap.set("n", "<esc>", vim.cmd.close, { buffer = buf, desc = "Close" })

  return buf, win
end

return Window
