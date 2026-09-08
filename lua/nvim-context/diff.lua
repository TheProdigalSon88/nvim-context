local utils = require("nvim-context.utils")

local M = {}

M.ns = vim.api.nvim_create_namespace("nvim-context.diff")

local highlight_group

function M.setup_highlight()
   local link = "DiffDelete"
   if vim.fn.hlexists("MiniDiffOverDelete") == 1 then
      link = "MiniDiffOverDelete"
   end
   vim.api.nvim_set_hl(0, "NvimContextChanged", {
      link = link,
   })
end

function M.setup()
   M.setup_highlight()
   if highlight_group then
      return
   end
   highlight_group = vim.api.nvim_create_augroup("NvimContextDiff", { clear = true })
   vim.api.nvim_create_autocmd("ColorScheme", {
      group = highlight_group,
      callback = M.setup_highlight,
   })
end

---@param buf number
---@param ns? number
function M.clear(buf, ns)
   if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, ns or M.ns, 0, -1)
   end
end

---@param buf number
---@param item vim.quickfix.entry
---@param ns number
---@return boolean applied
function M.preview_item(buf, item, ns)
   if not buf or not vim.api.nvim_buf_is_valid(buf) then
      return false
   end
   if not utils.is_context_item(item) then
      return false
   end
   local root = utils.git_root_for_item(item)
   if not root then
      return false
   end
   local diff = utils.range_diff(root, item, { source_buf = buf })
   if not diff then
      return false
   end
   local start_line = utils.qf_range(item)
   M.apply_range_marks(buf, ns, start_line, diff)
   return true
end

---@param buf number
---@param ns number
---@param start_line number
---@param diff RangeDiff
function M.apply_range_marks(buf, ns, start_line, diff)
   if not buf or not vim.api.nvim_buf_is_valid(buf) or not diff then
      return
   end
   local line_count = vim.api.nvim_buf_line_count(buf)

   ---@param row number
   ---@return number
   local function clamp_row(row)
      return math.max(1, math.min(row, line_count))
   end

   for _, hunk in ipairs(diff.hunks) do
      local old_start, old_count, new_start, new_count = hunk[1], hunk[2], hunk[3], hunk[4]

      if new_count > 0 and new_start > 0 then
         local row = clamp_row(start_line + new_start - 1)
         local end_row = clamp_row(start_line + new_start + new_count - 2)
         local hl = old_count == 0 and "DiffAdd" or "DiffChange"
         for l = row, end_row do
            vim.api.nvim_buf_set_extmark(buf, ns, l - 1, 0, {
               line_hl_group = hl,
               hl_eol = true,
               strict = false,
               priority = 160,
            })
         end
      end

      if old_count > 0 then
         local virt = {}
         for i = 0, old_count - 1 do
            virt[#virt + 1] = { { diff.old[old_start + i] or "", "DiffDelete" } }
         end
         local place_row
         local above
         if new_count == 0 and new_start <= 0 then
            place_row = start_line
            above = true
         elseif new_count == 0 then
            place_row = start_line + new_start - 1
            above = false
         else
            place_row = start_line + math.max(new_start, 1) - 1
            above = true
         end
         place_row = clamp_row(place_row)
         vim.api.nvim_buf_set_extmark(buf, ns, place_row - 1, 0, {
            virt_lines = virt,
            virt_lines_above = above,
            strict = false,
            priority = 160,
         })
      end
   end
end

return M
