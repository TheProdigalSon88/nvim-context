local utils = require("nvim-context.utils")
local Diff = require("nvim-context.diff")

local M = {}

local marked_buf ---@type number|nil
local last_id ---@type number|nil
local last_idx ---@type number|nil
local edit_group ---@type integer|nil
local scheduled = false
local enabled = true

local function clear()
   if marked_buf then
      Diff.clear(marked_buf)
   end
   if edit_group then
      pcall(vim.api.nvim_del_augroup_by_id, edit_group)
      edit_group = nil
   end
   marked_buf = nil
end

---@param buf number
---@param item vim.quickfix.entry
---@return boolean
local function buf_matches_item(buf, item)
   if item.bufnr and item.bufnr > 0 and buf == item.bufnr then
      return true
   end
   local abs = utils.qf_abspath(item)
   if not abs or abs == "" then
      return false
   end
   local name = vim.api.nvim_buf_get_name(buf)
   if name == "" then
      return false
   end
   return vim.fn.fnamemodify(name, ":p") == vim.fn.fnamemodify(abs, ":p")
end

---@param item vim.quickfix.entry
---@return number|nil
local function find_item_buf(item)
   local current = vim.api.nvim_get_current_buf()
   if vim.bo[current].buftype == "" and buf_matches_item(current, item) then
      return current
   end
   for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.bo[buf].buftype == "" and buf_matches_item(buf, item) then
         return buf
      end
   end
   return nil
end

---@param buf number
local function attach_edit_clear(buf)
   if edit_group then
      pcall(vim.api.nvim_del_augroup_by_id, edit_group)
   end
   edit_group = vim.api.nvim_create_augroup("NvimContextQfDiffEdit", { clear = true })
   vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWipeout" }, {
      group = edit_group,
      buffer = buf,
      callback = function()
         clear()
      end,
   })
end

local function apply_current()
   if not enabled or vim.bo.buftype ~= "" then
      return
   end
   local info = vim.fn.getqflist({ id = 0, idx = 0, size = 0 })
   if info.size == 0 then
      last_id, last_idx = nil, nil
      clear()
      return
   end
   if info.id == last_id and info.idx == last_idx then
      return
   end
   last_id, last_idx = info.id, info.idx

   local item = vim.fn.getqflist()[info.idx]
   clear()
   if not utils.is_context_item(item) then
      return
   end

   local buf = find_item_buf(item)
   if not buf then
      return
   end
   if Diff.preview_item(buf, item, Diff.ns) then
      marked_buf = buf
      attach_edit_clear(buf)
   end
end

local function maybe_show()
   if not enabled or vim.bo.buftype ~= "" then
      return
   end
   local info = vim.fn.getqflist({ id = 0, idx = 0, size = 0 })
   if info.size == 0 then
      if last_id or last_idx or marked_buf then
         last_id, last_idx = nil, nil
         clear()
      end
      return
   end
   if info.id == last_id and info.idx == last_idx then
      return
   end
   if scheduled then
      return
   end
   scheduled = true
   vim.schedule(function()
      scheduled = false
      apply_current()
   end)
end

function M.setup()
   enabled = true
   local group = vim.api.nvim_create_augroup("NvimContextQfDiff", { clear = true })
   vim.api.nvim_create_autocmd({ "SafeState", "BufEnter", "WinEnter", "CursorMoved" }, {
      group = group,
      callback = maybe_show,
   })
end

function M.disable()
   enabled = false
   last_id, last_idx = nil, nil
   clear()
end

function M.enable()
   enabled = true
   maybe_show()
end

---@return boolean enabled
function M.toggle()
   if enabled then
      M.disable()
      return false
   end
   M.enable()
   return true
end

return M
