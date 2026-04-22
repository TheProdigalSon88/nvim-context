local Utils = {}

local context_dir = nil

function Utils.init_context_dir()
  local ok = vim.fn.mkdir(context_dir, "p") == 1
  if not ok then
    vim.notify("Failed to create " .. context_dir, vim.log.levels.ERROR)
    return true
  end

  vim.notify("Created " .. context_dir, vim.log.levels.INFO)
  return true
end

function Utils.get_context_root()
  local path = vim.api.nvim_buf_get_name(0)
  local abs_path = vim.fn.fnamemodify(path, ":p")
  local git_root = vim.fn.finddir(".git", abs_path .. ";")
  return vim.fn.fnamemodify(git_root, ":h:h")
end

function Utils.check_context_exists()
  if not context_dir then
    local context_root = Utils.get_context_root()
    context_dir = context_root .. "/.context"
  end

  if vim.fn.isdirectory(context_dir) == 1 then
    vim.notify("Context directory exists at " .. context_dir, vim.log.levels.INFO)
    return true
  end

  vim.notify("No Context directory exists", vim.log.levels.WARN)
  return false
end

function Utils.get_context_subdirs()
  if not context_dir then
    local context_root = Utils.get_context_root()
    context_dir = context_root .. "/.context"
  end
  if vim.fn.isdirectory(context_dir) ~= 1 then
    vim.notify(context_dir .. " is not a directory", vim.log.levels.ERROR)
    return {}
  end

  local ok, entries = pcall(vim.fn.readdir, context_dir)
  if not ok then
    vim.notify("Failed to read directory " .. context_dir, vim.log.levels.ERROR)
    return {}
  end

  local result = {}
  for _, entry in ipairs(entries) do
    local full_path = context_dir .. "/" .. entry
    if vim.fn.isdirectory(full_path) == 1 and string.find(string.lower(entry), "context") then
      table.insert(result, entry)
    end
  end

  return result
end

function Utils.create_context(name, description)
  if not context_dir then
    local context_root = Utils.get_context_root()
    context_dir = context_root .. "/.context"
  end

  -- Ensure .context directory exists
  if vim.fn.isdirectory(context_dir) == 0 then
    local dir_ok = vim.fn.mkdir(context_dir, "p") == 1
    if not dir_ok then
      vim.notify("Failed to create context directory: " .. context_dir, vim.log.levels.ERROR)
      return
    end
  end

  local new_file = string.format("%s/%s_context.lua", context_dir, name)

  if vim.fn.filereadable(new_file) == 1 then
    vim.notify("Context file already exists: " .. new_file, vim.log.levels.WARN)
    return
  end

  local content = string.format('return {\n  description = %q,\n}', description)
  local file_ok = vim.fn.writefile(vim.split(content, "\n"), new_file) == 0
  if not file_ok then
    vim.notify("Failed to write context file: " .. new_file, vim.log.levels.ERROR)
    return
  end

  vim.notify("Created context: " .. new_file, vim.log.levels.INFO)
end

return Utils
