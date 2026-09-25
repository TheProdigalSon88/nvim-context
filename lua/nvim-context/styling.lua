local Styling = {}

local highlight_group_diff

local function apply_changed_hl()
   local link = "DiffDelete"
   if vim.fn.hlexists("MiniDiffOverDelete") == 1 then
      link = "MiniDiffOverDelete"
   end
   vim.api.nvim_set_hl(0, "NvimContextChanged", { link = link })
end

function Styling.setup_highlight_diff()
   if highlight_group_diff then
      return
   end
   highlight_group_diff = vim.api.nvim_create_augroup("NvimContextDiff", { clear = true })
   apply_changed_hl()
   vim.api.nvim_create_autocmd("ColorScheme", {
      group = highlight_group_diff,
      callback = apply_changed_hl,
   })
end

return Styling
