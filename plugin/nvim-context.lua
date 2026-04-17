local plugin = require("nvim-context")

vim.api.nvim_create_user_command("NvctxTest", function()
  print("nvim-context: " .. plugin.some_function())
end, {})
