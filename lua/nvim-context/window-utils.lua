local WinUtils = {}
local hint_keys = { "a", "s", "d", "f", "g" }

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

---@param buf number
function WinUtils.creation_labels(buf)
  local ns = vim.api.nvim_create_namespace("nvim_context_creation")
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
    virt_text = { { "  Name", "NvimContextLabel" } },
    virt_text_pos = "overlay",
  })
  vim.api.nvim_buf_set_extmark(buf, ns, 3, 0, {
    virt_text = { { "  Description", "NvimContextLabel" } },
    virt_text_pos = "overlay",
  })
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
  return NAME_LINE, DESC_START, DESC_END
end

--- Generate hint labels from the keys a, s, d, f, g.
--- Returns a flat list: first the 5 single-char labels, then 25 two-char
--- combinations (aa, as, ad, af, ag, sa, ss, …), giving 30 total hints.
---@param count number how many labels are needed
---@return table<string>
local function generate_hint_labels(count)
  local labels = {}

  -- Single-character labels first
  for _, k in ipairs(hint_keys) do
    if #labels >= count then
      return labels
    end
    table.insert(labels, k)
  end

  -- Two-character combinations
  for _, k1 in ipairs(hint_keys) do
    for _, k2 in ipairs(hint_keys) do
      if #labels >= count then
        return labels
      end
      table.insert(labels, k1 .. k2)
    end
  end

  return labels
end

---@param items table
---@param files boolean
---@return table<string>, table<string,number>,table<string>,table<string>
function WinUtils.labels_displaynames_entrytypes(items, files, has_items)
  local labels = has_items and generate_hint_labels(#items) or {}

  -- Map each label string to the 1-based item index it refers to
  local label_to_index = {}
  for i, label in ipairs(labels) do
    label_to_index[label] = i
  end

  -- Build display names from entries
  local display_names = {}
  local entry_types = {} -- track type per line for highlighting
  if has_items then
    for _, entry in ipairs(items) do
      if files then
        local name = vim.fn.fnamemodify(entry.path, ":t")
        if entry.type == "selection" then
          name = name .. " :" .. entry.lnum .. "-" .. entry.end_lnum
        end
        table.insert(entry_types, entry.type)
        table.insert(display_names, name)
      else
        table.insert(display_names, vim.fn.fnamemodify(entry, ":t:r"))
      end
    end
  end

  return labels, label_to_index, display_names, entry_types
end

function WinUtils.adaptive_sizing(has_items, display_names)
  local padding = 4 -- 2 chars left + 2 chars right
  local label_col_width = 5 -- "  a  " = 2 pad + label + pad to align name
  local max_item_width = 0
  if has_items then
    for _, name in ipairs(display_names) do
      max_item_width = math.max(max_item_width, #name)
    end
  end

  local content_width = label_col_width + max_item_width + padding
  local min_width = 40
  local max_width = math.floor(vim.o.columns * 0.7)
  local width = math.max(min_width, math.min(content_width, max_width))
  local inner = width - padding -- usable width inside padding

  return inner, width, content_width, min_width
end

function WinUtils.create_creation_buffer()
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

  return buf, height, width
end

function WinUtils.create_list_buffer(inner, has_items, display_names, labels, width)
  local sep = "  " .. string.rep("─", inner) .. "  "
  local item_lines = {}
  if has_items then
    for i, name in ipairs(display_names) do
      local label = labels[i] or ""
      local pad = string.rep(" ", 3 - #label)
      table.insert(item_lines, "  " .. label .. pad .. name)
    end
  else
    local msg = "No context files found"
    local left_pad = math.max(2, math.floor((width - #msg) / 2))
    table.insert(item_lines, string.rep(" ", left_pad) .. msg)
  end

  local lines = {}
  for _, line in ipairs(item_lines) do
    table.insert(lines, line)
  end
  table.insert(lines, sep)
  table.insert(lines, "")

  local max_height = math.floor(vim.o.lines * 0.6)
  local height = math.min(#lines, max_height)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("filetype", "nvim-context", { buf = buf })
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_set_option_value("undolevels", -1, { buf = buf })

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  return height, item_lines, lines, buf
end

function WinUtils.create_win(buf, height, width, title)
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
    "NormalFloat:Normal,FloatBorder:Special,FloatTitle:Title,CursorLine:NvimContextCursorLine",
    { win = win }
  )
  vim.api.nvim_set_option_value("cursorline", true, { win = win })

  return win
end

function WinUtils.usage_instructions(item_lines, has_items, buf, labels, entry_types)
  local ns = vim.api.nvim_create_namespace("nvim_context_files")
  local sep_line = #item_lines
  local hint_line = sep_line + 1

  vim.api.nvim_buf_set_extmark(buf, ns, sep_line, 0, { line_hl_group = "NvimContextSep" })

  if has_items then
    vim.api.nvim_buf_set_extmark(buf, ns, hint_line, 0, {
      virt_text = {
        { "  <CR> ", "NvimContextHintKey" },
        { "Select", "NvimContextHintText" },
        { "  ", "Normal" },
        { "a-g ", "NvimContextHintKey" },
        { "Quick select", "NvimContextHintText" },
        { "  ", "Normal" },
        { "j/k ", "NvimContextHintKey" },
        { "Navigate", "NvimContextHintText" },
        { "  ", "Normal" },
        { "q / <Esc> ", "NvimContextHintKey" },
        { "Cancel", "NvimContextHintText" },
      },
      virt_text_pos = "overlay",
    })
  else
    vim.api.nvim_buf_set_extmark(buf, ns, hint_line, 0, {
      virt_text = {
        { "  q / <Esc> ", "NvimContextHintKey" },
        { "Close", "NvimContextHintText" },
      },
      virt_text_pos = "overlay",
    })
  end

  -- Hint label highlights and selection line highlights
  if has_items then
    for i, label in ipairs(labels) do
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 2, {
        end_col = 2 + #label,
        hl_group = "NvimContextHintKey",
      })
      -- Highlight the name portion of selection entries
      if entry_types and entry_types[i] == "selection" then
        local name_start = 2 + #label + (3 - #label) -- "  " + label + pad
        local line_text = item_lines[i]
        vim.api.nvim_buf_set_extmark(buf, ns, i - 1, name_start, {
          end_col = #line_text,
          hl_group = "NvimContextSelection",
        })
      end
    end
  end

  if not has_items then
    vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { line_hl_group = "NvimContextEmpty" })
  end
end

function WinUtils.cursor_locking_creation(buf, win, NAME_LINE, DESC_START, DESC_END)
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
end

function WinUtils.cursor_locking(item_lines, win, buf)
  local last_item_line = #item_lines - 1
  local function clamp_cursor()
    if not vim.api.nvim_win_is_valid(win) then
      return
    end
    local cur = vim.api.nvim_win_get_cursor(win)[1] - 1
    if cur > last_item_line then
      vim.api.nvim_win_set_cursor(win, { last_item_line + 1, 0 })
    elseif cur < 0 then
      vim.api.nvim_win_set_cursor(win, { 1, 0 })
    end
  end

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    buffer = buf,
    callback = clamp_cursor,
  })

  vim.api.nvim_win_set_cursor(win, { 1, 0 })
end

function WinUtils.resizing(win, min_width, lines, content_width)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  local new_max_w = math.floor(vim.o.columns * 0.7)
  local new_width = math.max(min_width, math.min(content_width, new_max_w))
  local new_height = math.min(#lines, math.floor(vim.o.lines * 0.6))
  vim.api.nvim_win_set_config(win, {
    width = new_width,
    height = new_height,
    row = math.floor((vim.o.lines - new_height) / 2 - 1),
    col = math.floor((vim.o.columns - new_width) / 2 - 1),
  })
end

function WinUtils.creation_keymaps(buf, win, NAME_LINE, DESC_START, DESC_END, on_submit)
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
end

function WinUtils.select_item(index, win, items)
  local filepath = items and items[index]
  if not filepath then
    return
  end
  vim.api.nvim_win_close(win, true)
  return filepath
end

function WinUtils.keymap_selection_config(buf, win, entries, label_to_index, on_select)
  local needs_combos = #entries > #hint_keys

  for _, key in ipairs(hint_keys) do
    vim.keymap.set("n", key, function()
      if not needs_combos then
        local idx = label_to_index[key]
        if idx then
          local filepath = WinUtils.select_item(idx, win, entries)
          on_select(filepath)
        end
        return
      end

      local ok, second = pcall(vim.fn.getcharstr)
      if not ok then
        return
      end

      local combo = key .. second
      local combo_idx = label_to_index[combo]
      if combo_idx then
        local filepath = WinUtils.select_item(combo_idx, win, entries)
        on_select(filepath)
        return
      end

      local single_idx = label_to_index[key]
      if single_idx then
        local filepath = WinUtils.select_item(single_idx, win, entries)
        on_select(filepath)
      end
    end, { buffer = buf, desc = "Hint key " .. key })
  end
end

return WinUtils
