local utils = require("nvim-context.utils")
local log = require("nvim-context.log")

local M = {}

local ns = vim.api.nvim_create_namespace("nvim-context.trouble")

---@param item vim.quickfix.entry
---@return boolean
local function is_context_item(item)
   return type(item) == "table"
      and type(item.user_data) == "table"
      and type(item.user_data.git_hash) == "string"
      and item.user_data.git_hash ~= ""
end

---@param item vim.quickfix.entry
---@return string|nil
local function git_root_for_item(item)
   local abs = utils.qf_abspath(item)
   if abs and abs ~= "" then
      return vim.fs.root(abs, ".git")
   end
   return vim.fs.root(0, ".git")
end

local function setup_highlight()
   local link = "DiffDelete"
   if vim.fn.hlexists("MiniDiffOverDelete") == 1 then
      link = "MiniDiffOverDelete"
   end
   vim.api.nvim_set_hl(0, "NvimContextChanged", {
      link = link,
   })
end

---@param buf number
---@param start_line number
---@param diff RangeDiff
local function apply_diff_marks(buf, start_line, diff)
   local Render = require("trouble.view.render")
   local mark_ns = Render.ns
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
            vim.api.nvim_buf_set_extmark(buf, mark_ns, l - 1, 0, {
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
         vim.api.nvim_buf_set_extmark(buf, mark_ns, place_row - 1, 0, {
            virt_lines = virt,
            virt_lines_above = above,
            strict = false,
            priority = 160,
         })
      end
   end
end

---@param buf number
local function decorate_list(buf)
   if not vim.api.nvim_buf_is_valid(buf) then
      return
   end
   vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

   local ok, View = pcall(require, "trouble.view")
   if not ok then
      return
   end

   local view
   for _, entry in ipairs(View.get({ open = true, mode = "qflist" })) do
      if entry.view and entry.view.win and entry.view.win.buf == buf then
         view = entry.view
         break
      end
   end
   if not view or not view.renderer then
      return
   end

   for row, loc in pairs(view.renderer._locations) do
      local raw = loc.item and loc.item.item
      if is_context_item(raw) then
         local root = git_root_for_item(raw)
         if root and utils.range_diff(root, raw) then
            pcall(vim.api.nvim_buf_set_extmark, buf, ns, row - 1, 0, {
               line_hl_group = "NvimContextChanged",
               hl_eol = true,
            })
         end
      end
   end
end

---@param item trouble.Item
---@param ctx trouble.Preview
local function preview_context_item(item, ctx)
   if not ctx or not ctx.buf or not vim.api.nvim_buf_is_valid(ctx.buf) then
      return
   end
   local raw = item and item.item
   if not is_context_item(raw) then
      return
   end
   local root = git_root_for_item(raw)
   if not root then
      return
   end
   local diff = utils.range_diff(root, raw)
   if not diff then
      return
   end
   local Render = require("trouble.view.render")
   Render.reset(ctx.buf)
   local start_line = utils.qf_range(raw)
   apply_diff_marks(ctx.buf, start_line, diff)
end

function M.setup()
   local ok, qf = pcall(require, "trouble.sources.qf")
   if not ok then
      log.error("trouble.enabled but trouble.nvim is not installed")
      return
   end

   setup_highlight()
   qf.preview = preview_context_item

   local group = vim.api.nvim_create_augroup("NvimContextTrouble", { clear = true })
   vim.api.nvim_create_autocmd("ColorScheme", {
      group = group,
      callback = setup_highlight,
   })
   vim.api.nvim_create_autocmd("FileType", {
      group = group,
      pattern = "trouble",
      callback = function(ev)
         vim.api.nvim_create_autocmd("TextChanged", {
            group = group,
            buffer = ev.buf,
            callback = function()
               decorate_list(ev.buf)
            end,
         })
         vim.schedule(function()
            decorate_list(ev.buf)
         end)
      end,
   })
end

return M
