local winutils = require("nvim-context.window-utils")
local Window = {}

local function close(win)
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
end

local function close_keymaps(win, buf)
  vim.keymap.set("n", "q", function()
    close(win)
  end, { buffer = buf, desc = "Close" })
  vim.keymap.set("n", "<c-c>", function()
    close(win)
  end, { buffer = buf, desc = "Close" })
  vim.keymap.set("n", "<esc>", function()
    close(win)
  end, { buffer = buf, desc = "Close" })
end

function Window.open_floating_creation(title, on_submit)
  local buf, height, width = winutils.create_creation_buffer()
  local win = winutils.create_win(buf, height, width, title)
  local NAME_LINE, DESC_START, DESC_END = winutils.creation_labels(buf)
  winutils.cursor_locking_creation(buf, win, NAME_LINE, DESC_START, DESC_END)

  -- Start on the name field
  vim.api.nvim_win_set_cursor(win, { NAME_LINE + 1, 0 })

  -- ── Autocmds ─────────────────────────────────────────────────────────
  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
    buffer = buf,
    callback = function()
      close(win)
    end,
  })

  vim.api.nvim_create_autocmd("VimResized", {
    buffer = buf,
    callback = function()
      winutils.resizing(win, 52, height, vim.o.columns)
    end,
  })

  winutils.creation_keymaps(buf, win, NAME_LINE, DESC_START, DESC_END, on_submit)

  close_keymaps(win, buf)
end

---@param title string
---@param items table<string> list of file paths
---@param on_select function|nil callback receiving the selected file path
function Window.open_floating_selection_contexts(title, items, on_select)
  local has_items = items and #items > 0
  local labels, label_to_index, display_names = winutils.labels_displaynames_entrytypes(items, false, has_items)
  local inner, width, content_width, min_width = winutils.adaptive_sizing(has_items, display_names)
  local height, item_lines, lines, buf = winutils.create_list_buffer(inner, has_items, display_names, labels, width)
  local win = winutils.create_win(buf, height, width, title)
  winutils.usage_instructions(item_lines, has_items, buf, labels)
  winutils.cursor_locking(item_lines, win, buf)

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
      winutils.resizing(win, min_width, lines, content_width)
    end,
  })

  if has_items then
    vim.keymap.set("n", "<cr>", function()
      local cursor_line = vim.api.nvim_win_get_cursor(win)[1]
      local filepath = winutils.select_item(cursor_line, win, items)
      if on_select then
        on_select(filepath)
      end
    end, { buffer = buf, desc = "Select file" })
  end

  if has_items then
    winutils.keymap_selection_config(buf, win, items, label_to_index, on_select)
  end
  close_keymaps(win, buf)

  return buf, win
end

---@param title string
---@param entries table list of { type: "file"|"selection", path: string, start_line?: number, end_line?: number }
---@param on_select function|nil callback receiving the selected entry table
function Window.open_floating_selection_files(title, entries, on_select)
  local has_items = entries and #entries > 0
  local labels, label_to_index, display_names, entry_types =
    winutils.labels_displaynames_entrytypes(entries, true, has_items)
  local inner, width, content_width, min_width = winutils.adaptive_sizing(has_items, display_names)
  local height, item_lines, lines, buf = winutils.create_list_buffer(inner, has_items, display_names, labels, width)
  local win = winutils.create_win(buf, height, width, title)
  winutils.usage_instructions(item_lines, has_items, buf, labels, entry_types)
  winutils.cursor_locking(item_lines, win, buf)

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
      winutils.resizing(win, min_width, lines, content_width)
    end,
  })

  if has_items then
    vim.keymap.set("n", "<cr>", function()
      local cursor_line = vim.api.nvim_win_get_cursor(win)[1]
      local filepath = winutils.select_item(cursor_line, win, entries)
      if on_select then
        on_select(filepath)
      end
    end, { buffer = buf, desc = "Select file" })
  end

  if has_items then
    winutils.keymap_selection_config(buf, win, entries, label_to_index, on_select)
  end
  close_keymaps(win, buf)

  return buf, win
end

return Window
