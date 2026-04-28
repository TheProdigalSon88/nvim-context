vim.api.nvim_create_augroup("Context", { clear = true })

vim.api.nvim_create_user_command(
  "Context",
  ---@param opts Context.vim.user_command
  function(opts)
    local context = require("nvim-context")
    local subcommand = opts.fargs[1]
    local exists = context.check_and_create()

    if not exists then
      vim.notify("Failure creating context dir and it does not exists , check file permissions", vim.log.levels.ERROR)
      return
    end

    if not subcommand then
      context.toggle()
      return
    end

    local fn = context[subcommand]
    if type(fn) ~= "function" then
      vim.notify("Context: unknown subcommand '" .. subcommand .. "'", vim.log.levels.ERROR)
      return
    end
    fn()
  end,
  {
    desc = "Context",
    nargs = "*",
    complete = function(arg_lead)
      local context = require("nvim-context")
      local completions = {}
      for key, value in pairs(context) do
        if type(value) == "function" and key:find("^" .. arg_lead) then
          table.insert(completions, key)
        end
      end
      table.sort(completions)
      return completions
    end,
  }
)
