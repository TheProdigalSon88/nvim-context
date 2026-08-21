local Context = require("nvim-context")

vim.api.nvim_create_augroup("Context", { clear = true })

vim.api.nvim_create_user_command("Context", function(opts)
   local subcommand = opts.fargs[1]

   if not subcommand then
      vim.notify("Nvim Context no command selected", vim.log.levels.ERROR)
      return
   end

   local fn = Context[subcommand]
   if type(fn) ~= "function" then
      vim.notify("Nvim Context: unknown subcommand '" .. subcommand .. "'", vim.log.levels.ERROR)
      return
   end
   fn(opts.line1, opts.line2)
end, {
   desc = "Context",
   nargs = "*",
   range = true,
   complete = function(arg_lead)
      local completions = {}
      for key, value in pairs(Context) do
         if type(value) == "function" and key:find("^" .. arg_lead) then
            table.insert(completions, key)
         end
      end
      table.sort(completions)
      return completions
   end,
})
