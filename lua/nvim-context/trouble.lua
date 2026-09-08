local utils = require("nvim-context.utils")
local Diff = require("nvim-context.diff")
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
   Diff.apply_range_marks(ctx.buf, Render.ns, start_line, diff)
end

function M.setup()
   local ok, qf = pcall(require, "trouble.sources.qf")
   if not ok then
      log.error("trouble.enabled but trouble.nvim is not installed")
      return
   end

   Diff.setup_highlight()
   qf.preview = preview_context_item

   local group = vim.api.nvim_create_augroup("NvimContextTrouble", { clear = true })
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
