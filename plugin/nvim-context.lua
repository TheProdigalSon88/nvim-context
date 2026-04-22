vim.api.nvim_create_augroup("Context", { clear = true })

vim.api.nvim_create_user_command(
  "Context",
  ---@param opts Context.vim.user_command
  function(opts)
    local context = require("nvim-context")
    local subcommand = opts.fargs[1]

    if not subcommand then
      context.toggle()
      return
    end

    local fn = context[subcommand]
    if type(fn) == "function" then
      fn(unpack(opts.fargs, 2))
    else
      vim.notify("Context: unknown subcommand '" .. subcommand .. "'", vim.log.levels.ERROR)
    end
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
