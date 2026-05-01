local Context = {}
local Utils = require("nvim-context.utils")
local Window = require("nvim-context.window")
local Styling = require("nvim-context.styling")
local File = require("nvim-context.file-interaction")
Context.active_context = nil
Context.context_dir = nil

function Context.check_and_create()
  Styling.ensure_highlights()
  local exists, contextdir = Utils.check_context_and_create()
  Context.context_dir = contextdir
  return exists
end

function Context.toggle()
  local contexts = Utils.get_contexts(Context.context_dir)
  if #contexts == 0 then
    Context.create_context()
  else
    Window.open_floating_selection_contexts("Contexts", contexts, function(filepath)
      Context.active_context = filepath
      Utils.context_to_quickfix(Context.active_context)
      vim.notify("Active Context :" .. Context.active_context, vim.log.levels.INFO)
    end)
  end
end

function Context.create_context()
  Window.open_floating_creation("Create Context", function(name, description)
    Context.active_context = Utils.create_context(Context.context_dir, name, description)
  end)
end

function Context.add_selection_to_qf()
  local selection = File.selection()
  if selection then
    local filepath = selection and vim.fn.fnamemodify(selection.text:match("^(.+):%d"), ":p") or nil
    if filepath then
      local git_object = Utils.get_newest_commit_in_range(filepath, selection.lnum, selection.end_lnum)
      if git_object then
        Utils.add_to_context(Context.active_context, filepath, selection.lnum, selection.end_lnum, git_object)
      else
        Utils.add_to_context(Context.active_context, filepath, selection.lnum, selection.end_lnum)
      end
      vim.notify("Add " .. filepath .. " to Context " .. Context.active_context, vim.log.levels.INFO)
      File.highlight(selection)
      vim.fn.setqflist({ selection }, "a")
      return
    else
      vim.notify("No valid filepath", vim.log.levels.ERROR)
    end
  end
  vim.notify("Selction is nil", vim.log.levels.WARN)
end

function Context.add_file_to_context()
  if Context.active_context == nil then
    vim.notify("No Context Active", vim.log.levels.WARN)
    return
  end

  local filepath = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")
  if filepath == "" then
    vim.notify("No file associated with current buffer", vim.log.levels.WARN)
    return
  end

  local line_count = vim.api.nvim_buf_line_count(0)
  local git_object = Utils.get_newest_commit_in_range(filepath, 1, line_count)
  if git_object then
    Utils.add_to_context(Context.active_context, filepath, 1, line_count, git_object)
  else
    Utils.add_to_context(Context.active_context, filepath, 1, line_count)
  end
  vim.notify("Added " .. filepath .. " to Context " .. Context.active_context, vim.log.levels.INFO)
end

function Context.toggle_files()
  if Context.active_context == nil then
    vim.notify("No Context Active", vim.log.levels.WARN)
    return
  end
  local entries = Utils.get_context_files(Context.active_context)
  Window.open_floating_selection_files("Context Files", entries, function(entry)
    vim.cmd.edit(entry.path)
  end)
end

return Context
