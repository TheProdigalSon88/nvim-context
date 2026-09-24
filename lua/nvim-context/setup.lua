local log = require("nvim-context.log")
local utils = require("nvim-context.utils")
local qfix = require("nvim-context.qf")
local trouble = require("nvim-context.trouble")

local Setup = {}

---@type ContextOptions
Setup.defaults = {
   trouble = false,
   statusline = false,
   diagram = {
      keymap = "",
      enabled = false,
      snippets = {},
      image = {
         backend = "kitty",
      },
      renderer_options = {
         mermaid = { theme = "default" },
      },
   },
}

vim.api.nvim_create_autocmd("FileType", {
   pattern = "qf",
   callback = function()
      vim.wo.winbar = utils.current_display_title()
   end,
})

function Setup.setup_diagram_plugins(context)
   local image_ok, image = pcall(require, "image")
   if not image_ok then
      log.error("diagram.enabled but image.nvim is not installed")
      return
   end
   image.setup(context.Options.diagram.image)

   local diagram_ok, diagram = pcall(require, "diagram")
   if not diagram_ok then
      log.error("diagram.enabled but diagram.nvim is not installed")
      return
   end
   local integrations = context.Options.diagram.integrations or { require("diagram.integrations.markdown") }
   diagram.setup({
      integrations = integrations,
      renderer_options = context.Options.diagram.renderer_options,
   })
end

local function setup_highlight_diff()
   local link = "DiffDelete"
   if vim.fn.hlexists("MiniDiffOverDelete") == 1 then
      link = "MiniDiffOverDelete"
   end
   vim.api.nvim_set_hl(0, "NvimContextChanged", {
      link = link,
   })
end

local highlight_group_diff

function Setup.setup_diff()
   setup_highlight_diff()
   if highlight_group_diff then
      return
   end
   highlight_group_diff = vim.api.nvim_create_augroup("NvimContextDiff", { clear = true })
   vim.api.nvim_create_autocmd("ColorScheme", {
      group = highlight_group_diff,
      callback = setup_highlight_diff,
   })
end

function Setup.setup_qf()
   qfix.enabled = true
   qfix.viewer_enabled = true
   local group = vim.api.nvim_create_augroup("NvimContextQfDiff", { clear = true })
   vim.api.nvim_create_autocmd({ "SafeState", "BufEnter", "WinEnter", "CursorMoved" }, {
      group = group,
      callback = qfix.maybe_show,
   })
end

function Setup.setup_trouble()
   local ok, qf = pcall(require, "trouble.sources.qf")
   if not ok then
      log.error("trouble.enabled but trouble.nvim is not installed")
      return
   end

   setup_highlight_diff()
   qf.preview = trouble.preview_context_item

   local group = vim.api.nvim_create_augroup("NvimContextTrouble", { clear = true })
   vim.api.nvim_create_autocmd("FileType", {
      group = group,
      pattern = "trouble",
      callback = function(ev)
         vim.api.nvim_create_autocmd("TextChanged", {
            group = group,
            buffer = ev.buf,
            callback = function()
               trouble.decorate_list(ev.buf)
            end,
         })
         vim.schedule(function()
            trouble.decorate_list(ev.buf)
         end)
      end,
   })
end

return Setup
