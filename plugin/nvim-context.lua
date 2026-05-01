Context = require("nvim-context")

vim.api.nvim_create_augroup("Context", { clear = true })

local _in_context_autocmd = false

vim.api.nvim_create_autocmd("BufEnter", {
  group = "Context",
  pattern = "*",
  callback = function(args)
    if _in_context_autocmd then
      return
    end
    _in_context_autocmd = true

    local bufnr = args.buf
    local buftype = vim.bo[bufnr].buftype
    if buftype ~= "" then
      _in_context_autocmd = false
      return
    end
    local filepath = vim.api.nvim_buf_get_name(bufnr)
    if filepath == "" then
      _in_context_autocmd = false
      return
    end
    filepath = vim.fn.fnamemodify(filepath, ":p")
    if Context.active_context then
      require("nvim-context.utils").file_locations_to_loclist(filepath, Context.active_context)
    end

    _in_context_autocmd = false
  end,
})

vim.api.nvim_create_user_command(
  "Context",
  ---@param opts Context.vim.user_command
  function(opts)
    local subcommand = opts.fargs[1]
    local exists = Context.check_and_create()

    if not exists then
      vim.notify("Failure creating context dir and it does not exists , check file permissions", vim.log.levels.ERROR)
      return
    end

    if not subcommand then
      Context.toggle()
      return
    end

    local fn = Context[subcommand]
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
