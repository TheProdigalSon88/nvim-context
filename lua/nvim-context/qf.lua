local utils = require("nvim-context.utils")
local Diff = require("nvim-context.diff")
local buffer = require("nvim-context.buffer")

local M = {}

local marked_buf ---@type number|nil
local last_id ---@type number|nil
local last_idx ---@type number|nil
local last_viewer_id ---@type number|nil
local last_viewer_idx ---@type number|nil
local edit_group ---@type integer|nil
local scheduled = false
local enabled = true
local viewer_enabled = true

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

local function diagram_enabled()
   local ok, Context = pcall(require, "nvim-context")
   return ok and Context.Options and Context.Options.diagram and Context.Options.diagram.enabled or false
end

local function apply_viewer()
   if not viewer_enabled then
      return
   end
   local info = vim.fn.getqflist({ id = 0, idx = 0, size = 0 })
   if info.size == 0 then
      last_viewer_id, last_viewer_idx = nil, nil
      buffer.close_qf_follow()
      return
   end
   if info.id == last_viewer_id and info.idx == last_viewer_idx then
      return
   end
   last_viewer_id, last_viewer_idx = info.id, info.idx

   local item = vim.fn.getqflist()[info.idx]
   if not utils.is_context_item(item) then
      buffer.close_qf_follow()
      return
   end
   buffer.show_qf_follow(item, {
      diagram_enabled = diagram_enabled(),
      on_close = function()
         viewer_enabled = false
         last_viewer_id, last_viewer_idx = nil, nil
      end,
   })
end

local function maybe_show()
   if scheduled or (not enabled and not viewer_enabled) then
      return
   end
   local info = vim.fn.getqflist({ id = 0, idx = 0, size = 0 })
   local viewer_stale = viewer_enabled
      and (
         (info.size == 0 and (last_viewer_id ~= nil or last_viewer_idx ~= nil))
         or (info.size > 0 and (info.id ~= last_viewer_id or info.idx ~= last_viewer_idx))
      )
   local diff_stale = enabled
      and vim.bo.buftype == ""
      and (
         (info.size == 0 and (last_id ~= nil or last_idx ~= nil or marked_buf ~= nil))
         or (info.size > 0 and (info.id ~= last_id or info.idx ~= last_idx))
      )
   if not viewer_stale and not diff_stale then
      return
   end
   scheduled = true
   vim.schedule(function()
      scheduled = false
      apply_viewer()
      apply_current()
   end)
end

function M.setup()
   enabled = true
   viewer_enabled = true
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

function M.disable_viewer()
   viewer_enabled = false
   last_viewer_id, last_viewer_idx = nil, nil
   buffer.close_qf_follow()
end

function M.enable_viewer()
   viewer_enabled = true
   last_viewer_id, last_viewer_idx = nil, nil
   apply_viewer()
end

---@return boolean enabled
function M.toggle_viewer()
   if viewer_enabled then
      M.disable_viewer()
      return false
   end
   M.enable_viewer()
   return true
end

return M
