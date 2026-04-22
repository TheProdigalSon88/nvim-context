local Context = {}
local Utils = require("nvim-context.utils")
local Window = require("nvim-context.window")

function Context.toggle()
  local context_exists = Utils.check_context_exists()
  if context_exists then
    local contextDirs = Utils.get_context_subdirs()
    if #contextDirs == 0 then
      local items = {
        { label = "Create Context", action = Context.create_context },
      }
      Window.open_floating_selection("Contexts", items)
    end
  else
    local items = {
      { label = "Initialize context directory", action = Utils.init_context_dir },
    }
    Window.open_floating_selection("No Context directory found", items)
  end
end

function Context.create_context()
  Window.open_floating_creation("Create Context", function(name, description)
    Utils.create_context(name, description)
  end)
end

return Context
