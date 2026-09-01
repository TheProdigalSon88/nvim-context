local sql = require("nvim-context.sql")
local utils = require("nvim-context.utils")
local buffer = require("nvim-context.buffer")
local log = require("nvim-context.log")

local Context = {}
local defaults = {
   trouble = false,
   statusline = false,
   diagram = {
      enabled = false,
      snippets = {},
   },
}

vim.api.nvim_create_autocmd("FileType", {
   pattern = "qf",
   callback = function()
      local title = vim.fn.getqflist({ title = 0 }).title or ""
      vim.wo.winbar = title ~= "" and title or ""
   end,
})

function Context.setup(opts)
   Context.Options = vim.tbl_deep_extend("force", defaults, opts or {})
end

function Context.AddReference()
   if not Context.root then
      Context.root = vim.fs.root(0, ".git")
      if not Context.root then
         log.error("not inside a git repository")
         return
      end
   end
   local bufnr = vim.api.nvim_get_current_buf()
   local display_text, base_text, start_line, end_line = utils.getLines(bufnr)
   ---@type ReferenceBuffer
   local referenceBuffer = {
      default = "",
      code = base_text,
      source_buf = bufnr,
      diagram_keymap = Context.Options.diagram.enabled and Context.Options.diagram.keymap or nil,
      diagram_enabled = Context.Options.diagram.enabled,
      diagram_snippets = Context.Options.diagram.enabled and Context.Options.diagram.snippets or nil,
   }
   buffer.open_reference_editor(referenceBuffer, function(description)
      ---@type vim.quickfix.entry
      local item = {
         filename = utils.get_file_path(bufnr, Context.root),
         bufnr = bufnr,
         lnum = start_line,
         end_lnum = end_line,
         col = 1,
         text = display_text,
         ---@type UserData
         user_data = {
            id = nil,
            description = description,
            base_text = base_text,
            display_text = display_text,
            git_hash = utils.git_hash(),
            timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
         },
      }

      vim.fn.setqflist({ item }, "a")
      if Context.Options.trouble then
         require("trouble").refresh("qflist")
      end
      log.info("added reference to context")
   end)
end

---@param idx? number
function Context.EditReference(idx)
   if idx == nil and vim.bo.filetype ~= "qf" then
      return
   end
   local qflist = vim.fn.getqflist()
   ---@type vim.quickfix.entry
   local item = qflist[idx or vim.fn.line(".")]
   if not item then
      return
   end
   ---@type UserData
   local user_data = item.user_data
   local current_description = user_data.description
   local base_text = user_data.base_text
   local display_text = user_data.display_text
   local id = user_data.id
   local current_idx = idx or vim.fn.line(".")
   ---@type ReferenceBuffer
   local referenceBuffer = {
      default = current_description,
      code = base_text,
      source_buf = item.bufnr,
      diagram_keymap = Context.Options.diagram.enabled and Context.Options.diagram.keymap or nil,
      diagram_enabled = Context.Options.diagram.enabled,
      diagram_snippets = Context.Options.diagram.enabled and Context.Options.diagram.snippets or nil,
   }

   buffer.open_reference_editor(referenceBuffer, function(description)
      if description == nil then
         return
      end
      item.text = display_text
      item.user_data = vim.tbl_extend("force", user_data, {
         description = description,
         base_text = base_text,
         display_text = display_text,
         id = id,
      })
      local updated_qflist = vim.fn.getqflist()
      local fresh_idx = utils.find_qf_index(updated_qflist, item) or current_idx
      updated_qflist[fresh_idx] = item
      vim.fn.setqflist({}, "r", { items = updated_qflist })
      if Context.Options.trouble then
         require("trouble").refresh("qflist")
      end
      log.info("updated context reference")
   end)
end

function Context.LoadContext()
   if not Context.root then
      Context.root = vim.fs.root(0, ".git")
      if not Context.root then
         log.error("not inside a git repository")
         return
      end
   end

   ---@type boolean,ContextListItem[]
   local ok, titles = pcall(sql.list_titles, Context.root)
   if not ok then
      log.error("failed to read contexts: " .. tostring(titles))
      return
   end

   ---@type ContextListItem
   local new_context = { title = "+ New Context", id = "" }
   local titles_with_new = vim.list_extend({}, titles)
   table.insert(titles_with_new, new_context)

   vim.ui.select(titles_with_new, {
      prompt = "Load context:",
      format_item = function(item)
         return item.title
      end,
   }, function(choice)
      if not choice then
         return
      end

      if choice.title == new_context.title then
         vim.ui.input({ prompt = "New context title: " }, function(title)
            if title == nil or title == "" then
               log.error("context must have title")
               return
            end
            vim.fn.setqflist({}, " ", { title = title, items = {} })
            log.info("created context " .. title)
         end)
         return
      end

      local load_ok, data = pcall(sql.load_list, Context.root, choice.id)
      if not load_ok or not data then
         log.error("failed to load context" .. tostring(data))
         return
      end
      ---@type vim.fn.setqflist.what
      local selectedContext = {
         title = data.title ~= "" and data.title or choice.title,
         items = utils.dbrows_to_qfitems(data.items, Context.root),
         context = { description = data.description, id = data.id },
      }
      vim.fn.setqflist({}, " ", selectedContext)
      log.info("loaded context: " .. choice.title)
   end)
end

function Context.AddEditContextTitle()
   Context.current_title = vim.fn.getqflist({ title = 0 }).title or ""

   vim.ui.input({ prompt = "Quickfix title: ", default = Context.current_title }, function(title)
      if title == nil or title == "" then
         log.error("context must have title")
         return
      end
      vim.fn.setqflist({}, "r", { title = title })
      if Context.Options.trouble then
         require("trouble").refresh("qflist")
      end
      log.info("added/updated context title")
   end)
end

function Context.AddEditContextDescription()
   local context = vim.fn.getqflist({ context = 0 }).context
   local current_description = (type(context) == "table" and context.description) or ""
   ---@type ReferenceBuffer
   local referenceBuffer = {
      default = current_description,
      diagram_keymap = Context.Options.diagram.enabled and Context.Options.diagram.keymap or nil,
      diagram_enabled = Context.Options.diagram.enabled,
      diagram_snippets = Context.Options.diagram.enabled and Context.Options.diagram.snippets or nil,
   }

   buffer.open_reference_editor(referenceBuffer, function(description)
      if description == nil then
         return
      end
      local new_context = type(context) == "table" and vim.deepcopy(context) or {}
      new_context.description = description
      vim.fn.setqflist({}, "r", { context = new_context })
      if Context.Options.trouble then
         require("trouble").refresh("qflist")
      end
      log.info("added/updated context description")
   end)
end

function Context.SaveContext()
   local title = vim.fn.getqflist({ title = 0 }).title
   if title == "" or title == nil then
      log.error("set a title for context before saving")
      return
   end

   if not Context.root then
      Context.root = vim.fs.root(0, ".git")
      if not Context.root then
         log.error("not inside a git repository")
         return
      end
   end

   ---@type vim.fn.setqflist.what
   local info = vim.fn.getqflist({ context = 0, items = 0, title = 0 })

   local db_id = type(info.context) == "table" and info.context.id or nil
   local previous_ok, previous_context = true, nil
   if db_id then
      previous_ok, previous_context = pcall(sql.load_list, Context.root, db_id)
      if not previous_ok then
         previous_context = nil
      end
   end

   ---@type boolean,boolean,Context
   local conv_ok, new, context = pcall(utils.qflist_to_context, info, previous_context)
   if not conv_ok then
      log.error("failed to build context: " .. tostring(context))
      return
   end

   ---@type ContextItem, UpdateContextItem
   local new_items, updated_items =
      utils.qfitems_to_dbrows(info.items, previous_context and previous_context.items, Context.root)

   if new then
      local ok, new_id = pcall(sql.insert_context, Context.root, context, new_items)
      if not ok then
         log.error("failed to save context: " .. tostring(new_id))
         return
      end
      local saved_ctx = type(info.context) == "table" and vim.deepcopy(info.context) or {}
      saved_ctx.id = new_id
      vim.fn.setqflist({}, "r", { context = saved_ctx })
      log.info("saved context: " .. title)
   elseif previous_ok then
      local ok, err = pcall(
         sql.update_context,
         Context.root,
         context,
         new_items,
         updated_items,
         previous_context and previous_context.title
      )
      if not ok then
         log.error("failed to update context: " .. tostring(err))
         return
      end
      log.info("updated context: " .. title)
   else
      log.error("failed to load previous context: " .. tostring(previous_context))
   end
end

---@param line1? number
---@param line2? number
function Context.ShowReference(line1, line2)
   if not Context.root then
      Context.root = vim.fs.root(0, ".git")
      if not Context.root then
         log.error("not inside a git repository")
         return
      end
   end
   local bufnr = vim.api.nvim_get_current_buf()
   local start_line, end_line
   if line1 and line2 then
      start_line = line1
      end_line = line2
   end
   local filename = utils.get_file_path(bufnr, Context.root)
   local ok, items = pcall(sql.get_items_at_line, Context.root, filename, start_line, end_line)
   if not ok then
      log.error("failed to query references: " .. tostring(items))
      return
   end
   if not items or #items == 0 then
      log.info("no context references found at cursor")
      return
   end

   buffer.open_references_viewer(items, bufnr, function(item)
      local load_ok, data = pcall(sql.load_list, Context.root, item.list_id)
      if not load_ok or not data then
         log.error("failed to load context: " .. tostring(data))
         return
      end
      vim.fn.setqflist({}, " ", {
         title = data.title,
         items = utils.dbrows_to_qfitems(data.items, Context.root),
         context = { description = data.description, id = data.id },
      })
      log.info("loaded context: " .. data.title)
      buffer.open_reference_editor({
         default = item.description,
         code = item.base_text,
         source_buf = bufnr,
         readonly = true,
         diagram_keymap = nil,
         diagram_enabled = Context.Options.diagram.enabled,
      }, function() end)
   end, {
      diagram_enabled = Context.Options.diagram.enabled,
   })
end

function Context.OpenNoteViewer()
   if not Context.root then
      Context.root = vim.fs.root(0, ".git")
      if not Context.root then
         log.error("not inside a git repository")
         return
      end
   end

   if #vim.fn.getqflist() == 0 then
      log.error("quickfix list is empty")
      return
   end

   local function save_item(item, description)
      if not item then
         return
      end
      local qflist = vim.fn.getqflist()
      local idx = utils.find_qf_index(qflist, item)
      if not idx then
         log.error("could not locate quickfix entry to update")
         return
      end
      local ud = type(item.user_data) == "table" and vim.deepcopy(item.user_data) or {}
      ud.description = description
      qflist[idx].user_data = ud
      vim.fn.setqflist({}, "r", { items = qflist })
      if Context.Options and Context.Options.trouble then
         require("trouble").refresh("qflist")
      end
      log.info("updated note")
   end

   local source_win = vim.api.nvim_get_current_win()
   buffer.open_qf_note_viewer(save_item)

   -- Restore focus to source window before jumping, so cc 1 lands there (not in the note pane).
   vim.api.nvim_set_current_win(source_win)
   vim.cmd("cc 1")
end

function Context.StatuslineComponent()
   return {
      function()
         return vim.fn.getqflist({ title = 0 }).title or ""
      end,
      cond = function()
         if not Context.Options.statusline then
            return false
         end
         local title = vim.fn.getqflist({ title = 0 }).title
         return title ~= nil and title ~= ""
      end,
   }
end

function Context.EditTroubleItemNote(_, ctx)
   if Context.Options.trouble then
      local raw_item = ctx and ctx.item and ctx.item.item
      if not raw_item then
         log.error("no quickfix reference under cursor")
         return
      end

      local qflist = vim.fn.getqflist()
      local idx = utils.find_qf_index(qflist, raw_item)
      if not idx then
         log.error("could not locate context reference")
         return
      end
      Context.EditReference(idx)
   else
      log.info("trouble not enabled")
   end
end

return Context
