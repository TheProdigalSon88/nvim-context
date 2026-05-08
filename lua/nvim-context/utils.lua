local Utils = {}
local private = {}

private.cache = {}

function private.get_cache_key(filepath, active_context)
  local mtime = vim.fn.getftime(active_context)
  return filepath .. "::" .. active_context .. "::" .. tostring(mtime)
end

function private.invalidate()
  private.cache = {}
end

function Utils.invalidate_cache()
  private.invalidate()
end

---@return string
function private.get_context_root()
  local path = vim.api.nvim_buf_get_name(0)
  local abs_path = vim.fn.fnamemodify(path, ":p")
  local git_root = vim.fn.finddir(".git", abs_path .. ";")
  return vim.fn.fnamemodify(git_root, ":h:h")
end

---@param context_path string
---@param context table
---@return boolean
function private.write_context(context_path, context)
  local lines = {}
  table.insert(lines, "return {")
  table.insert(lines, string.format("  description = %q,", context.description or ""))
  table.insert(lines, "  files = {")

  for filepath, ranges in pairs(context.files) do
    table.insert(lines, string.format("    [%q] = {", filepath))
    for _, range in ipairs(ranges) do
      local git_str = "{}"
      if range.git_object and next(range.git_object) then
        local parts = {}
        for k, v in pairs(range.git_object) do
          table.insert(parts, string.format("%s = %q", k, tostring(v)))
        end
        git_str = "{ " .. table.concat(parts, ", ") .. " }"
      end
      table.insert(
        lines,
        string.format(
          "      { lnum = %d, end_lnum = %d, git_object = %s , description = %s },",
          range.lnum,
          range.end_lnum,
          git_str,
          range.description
        )
      )
    end
    table.insert(lines, "    },")
  end

  table.insert(lines, "  },")
  table.insert(lines, "}")

  local content = table.concat(lines, "\n")
  local ok = vim.fn.writefile(vim.split(content, "\n"), context_path) == 0
  if not ok then
    vim.notify("Failed to write context file: " .. context_path, vim.log.levels.ERROR)
  end
  return ok
end

---@return boolean,string
function Utils.check_context_and_create()
  local context_dir = private.get_context_root() .. "/.context"
  if vim.fn.isdirectory(context_dir) == 1 then
    vim.notify("Context directory exists at " .. context_dir, vim.log.levels.INFO)
    return true, context_dir
  end

  local ok = vim.fn.mkdir(context_dir, "p") == 1
  if not ok then
    vim.notify("Failed to create " .. context_dir, vim.log.levels.ERROR)
    return false, context_dir
  end

  vim.notify("Created " .. context_dir, vim.log.levels.INFO)
  return true, context_dir
end

---@param context_dir string
---@return table<string>
function Utils.get_contexts(context_dir)
  local ok, entries = pcall(vim.fn.readdir, context_dir)
  if not ok then
    vim.notify("Failed to read directory " .. context_dir, vim.log.levels.ERROR)
    return {}
  end

  local result = {}
  for _, entry in ipairs(entries) do
    local full_path = context_dir .. "/" .. entry
    if vim.fn.filereadable(full_path) == 1 and vim.fn.fnamemodify(entry, ":e") == "lua" then
      table.insert(result, full_path)
    end
  end

  return result
end

---@param context_dir string
---@param context_name string
---@param filepath string
---@param lnum integer
---@param end_lnum integer
---@param description string
---@param git_object? table
---@return boolean
function Utils.add_to_context(context_name, filepath, lnum, end_lnum, description, git_object)
  vim.notify("context_name " .. context_name, vim.log.levels.INFO)
  if vim.fn.filereadable(context_name) ~= 1 then
    vim.notify("Context file not found: " .. context_name, vim.log.levels.ERROR)
    return false
  end

  local context = dofile(context_name)
  if type(context) ~= "table" or type(context.files) ~= "table" then
    vim.notify("Invalid context file: " .. context_name, vim.log.levels.ERROR)
    return false
  end

  if context.files[filepath] then
    for _, existing in ipairs(context.files[filepath]) do
      if existing.lnum == lnum and existing.end_lnum == end_lnum then
        vim.notify("Range already in context: " .. filepath .. ":" .. lnum .. "-" .. end_lnum, vim.log.levels.WARN)
        return true
      elseif lnum and end_lnum then
        vim.notify("File already in context: " .. filepath, vim.log.levels.WARN)
        return true
      end
    end
  else
    context.files[filepath] = {}
  end

  table.insert(context.files[filepath], {
    lnum = lnum,
    end_lnum = end_lnum,
    git_object = git_object or {},
    description = description or nil,
  })

  local write_ok = private.write_context(context_name, context)
  if not write_ok then
    return false
  end

  private.invalidate()

  vim.notify("Added " .. filepath .. " to context", vim.log.levels.INFO)
  return true
end

---@param context_dir string
---@param name string
---@param description string
---@return string|nil
function Utils.create_context(context_dir, name, description)
  local new_file = string.format("%s/%s.lua", context_dir, name)

  if vim.fn.filereadable(new_file) == 1 then
    vim.notify("Context file already exists: " .. name, vim.log.levels.WARN)
    return new_file
  end

  local content = string.format('return {\n  type = "context",\n  description = %q ,\n  files = {},\n}', description)
  local file_ok = vim.fn.writefile(vim.split(content, "\n"), new_file) == 0
  if not file_ok then
    vim.notify("Failed to write context file: " .. new_file, vim.log.levels.ERROR)
    return nil
  end

  vim.notify("Created context: " .. new_file, vim.log.levels.INFO)
  private.invalidate()
  return new_file
end

---@param context_name string
---@return table entries list of { type: "file"|"selection", path: string, start_line?: number, end_line?: number }
function Utils.get_context_files(context_name)
  if vim.fn.filereadable(context_name) ~= 1 then
    vim.notify("Context file not found: " .. context_name, vim.log.levels.ERROR)
    return {}
  end

  local ok, context = pcall(dofile, context_name)
  if not ok or type(context) ~= "table" or type(context.files) ~= "table" then
    vim.notify("Invalid context file: " .. context_name, vim.log.levels.ERROR)
    return {}
  end

  local entries = {}
  for filepath, _ in pairs(context.files) do
    table.insert(entries, {
      path = filepath,
    })
  end
  return entries
end

---@param filepath string absolute or relative file path
---@param start_line number first line of the range (1-indexed)
---@param end_line number last line of the range (1-indexed)
---@return table|nil commit { hash, author, date, subject } of the newest commit, or nil
function Utils.get_newest_commit_in_range(filepath, start_line, end_line)
  local abs_path = vim.fn.fnamemodify(filepath, ":p")
  local git_dir = vim.fn.finddir(".git", abs_path .. ";")
  if git_dir == "" then
    vim.notify("Not inside a git repository", vim.log.levels.ERROR)
    return nil
  end

  local git_root = vim.fn.fnamemodify(git_dir, ":h")
  local rel_path = vim.fn.fnamemodify(abs_path, ":." .. git_root)
  -- Make path relative to git root
  if vim.startswith(abs_path, git_root) then
    rel_path = abs_path:sub(#git_root + 2) -- +2 to skip trailing /
  end

  local cmd = string.format(
    "git -C %s log -L %d,%d:%s --no-patch --format='%%H%%n%%an%%n%%ai%%n%%s'",
    vim.fn.shellescape(git_root),
    start_line,
    end_line,
    vim.fn.shellescape(rel_path)
  )

  local output = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 or #output < 4 then
    return nil
  end

  -- First 4 lines correspond to the newest commit (git log outputs newest first)
  return {
    hash = output[1],
    author = output[2],
    date = output[3],
    subject = output[4],
  }
end

---@param context_name string path to a .context directory lua file
function Utils.context_to_quickfix(context_name)
  if vim.fn.filereadable(context_name) ~= 1 then
    vim.notify("Context file not found: " .. context_name, vim.log.levels.ERROR)
    return
  end

  local ok, context = pcall(dofile, context_name)
  if not ok or type(context) ~= "table" or type(context.files) ~= "table" then
    vim.notify("Invalid context file: " .. context_name, vim.log.levels.ERROR)
    return
  end

  local items = {}
  for filepath, ranges in pairs(context.files) do
    for _, range in ipairs(ranges) do
      local priority = range.priority or 0
      table.insert(items, {
        filename = filepath,
        lnum = range.lnum,
        end_lnum = range.end_lnum,
        text = range.description,
        _priority = priority,
      })
    end
  end

  table.sort(items, function(a, b)
    if a._priority ~= b._priority then
      return a._priority > b._priority
    end
    return a.filename < b.filename
  end)

  if #items == 0 then
    vim.notify("No files in context: " .. context_name, vim.log.levels.WARN)
    return
  end

  local title = vim.fn.fnamemodify(context_name, ":t:r")
  vim.fn.setqflist({}, " ", { title = title, items = items })
end

---@param filepath string absolute path of the file to filter locations for
---@param active_context string path to the active .context/*.lua file
function Utils.file_locations_to_loclist(filepath, active_context)
  if vim.fn.filereadable(active_context) ~= 1 then
    vim.notify("Context file not found: " .. active_context, vim.log.levels.ERROR)
    return
  end

  local abs_filepath = vim.fn.fnamemodify(filepath, ":p")
  local cache_key = private.get_cache_key(abs_filepath, active_context)
  local cached = private.cache[cache_key]

  if cached then
    if cached.items == nil then
      vim.notify("No locations for " .. abs_filepath .. " in context", vim.log.levels.WARN)
      return
    end
    local winid = vim.api.nvim_get_current_win()
    vim.fn.setloclist(winid, {}, " ", { title = cached.title, items = cached.items })
    return
  end

  local ok, context = pcall(dofile, active_context)
  if not ok or type(context) ~= "table" or type(context.files) ~= "table" then
    vim.notify("Invalid context file: " .. active_context, vim.log.levels.ERROR)
    return
  end

  local ranges = context.files[abs_filepath]
  if not ranges or #ranges == 0 then
    private.cache[cache_key] = { items = nil, title = nil }
    vim.notify("No locations for " .. abs_filepath .. " in context", vim.log.levels.WARN)
    return
  end

  local items = {}
  for _, range in ipairs(ranges) do
    table.insert(items, {
      filename = abs_filepath,
      lnum = range.lnum,
      end_lnum = range.end_lnum,
      text = range.description,
    })
  end

  table.sort(items, function(a, b)
    return a.lnum < b.lnum
  end)

  local title = vim.fn.fnamemodify(active_context, ":t:r") .. ": " .. vim.fn.fnamemodify(abs_filepath, ":t")
  private.cache[cache_key] = { items = items, title = title }

  local winid = vim.api.nvim_get_current_win()
  vim.fn.setloclist(winid, {}, " ", { title = title, items = items })
end

return Utils
