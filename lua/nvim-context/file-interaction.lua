local File = {}

---@return Context.File.selection?
File.selection = function()
  local mode = vim.fn.mode()
  local start_line, end_line

  if mode == "v" or mode == "V" then
    -- Update <,> registers and escape from visual mode
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", true)

    start_line = vim.fn.getpos("'<")[2]
    end_line = vim.fn.getpos("'>")[2]
  elseif mode == "n" then
    start_line = 1
    end_line = vim.api.nvim_buf_line_count(0)
  else
    vim.notify("selection must be called in normal or visual mode", vim.log.levels.INFO)
    return
  end

  vim.notify("selected lines: [" .. start_line .. ", " .. end_line .. "]", vim.log.levels.INFO)

  local bufnr = vim.api.nvim_get_current_buf()
  local bufname = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":~:.")
  -- NOTE: this bufname is simply relative to cwd and does not implement project root discovery

  local text = (start_line == end_line) and (bufname .. ":" .. start_line)
    or (bufname .. ":" .. start_line .. "-" .. end_line)

  ---@type Context.File.selection
  local item = {
    bufnr = bufnr,
    lnum = start_line,
    end_lnum = end_line,
    text = text,
    pattern = "",
    valid = 1,
  }

  return item
end

--- Highlight quickfix/loclist item
---@param item Context.File.selection Item to highlight
---@param timeout integer? duration in milliseconds
---@return nil
File.highlight = function(item, timeout)
  timeout = 100 or timeout
  local ns_id = vim.api.nvim_create_namespace("ctx_highlight")
  local buf = item.bufnr
  local start_line = item.lnum
  local end_line = item.end_lnum or item.lnum

  -- Apply highlight
  for i = start_line, end_line do
    vim.api.nvim_buf_add_highlight(buf, ns_id, "IncSearch", i - 1, 0, -1)
  end

  -- Clear highlight after timeout
  vim.defer_fn(function()
    vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)
  end, timeout)

  vim.notify("highlighted lines: [" .. start_line .. ", " .. end_line .. "]")
end

---@type Context.File
return File
