local Styling = {}

--- Define highlight groups for the creation form.
function Styling.ensure_highlights()
  local function hi(name, opts)
    local existing = vim.api.nvim_get_hl(0, { name = name })
    if vim.tbl_isempty(existing) then
      vim.api.nvim_set_hl(0, name, opts)
    end
  end
  hi("NvimContextLabel", { link = "Title" })
  hi("NvimContextSep", { link = "FloatBorder" })
  hi("NvimContextPlaceholder", { link = "Comment" })
  hi("NvimContextHintKey", { link = "Special" })
  hi("NvimContextHintText", { link = "Comment" })
  hi("NvimContextCursorLine", { link = "CursorLine" })
  hi("NvimContextEmpty", { link = "Comment" })
  hi("NvimContextSelection", { link = "String" })
  hi("NvimContextSelectionRange", { link = "Number" })
end

return Styling
