local Context = {}
-- Publish before requiring utils: utils.lua requires this module, and Lua
-- has not finished loading it yet (circular require).
package.loaded["nvim-context"] = Context

---@type ContextStackItem[]
Context.stack = {}

local sql = require("nvim-context.sql")
local utils = require("nvim-context.utils")
local buffer = require("nvim-context.buffer")
local log = require("nvim-context.log")
local setup = require("nvim-context.setup")
local diff = require("nvim-context.diff")

local STACK_TYPES = { "context", "flow" }

local open_context_form
local focus_current_qf_item

local function bind_qf_context(key, direction)
  vim.keymap.set("n", key, function()
    local ok, bracketed = pcall(require, "mini.bracketed")
    if ok and type(bracketed.quickfix) == "function" then
      bracketed.quickfix(direction)
    else
      pcall(vim.cmd, direction == "forward" and "silent! cnext" or "silent! cprev")
    end
    focus_current_qf_item()
  end, {
    desc = direction == "forward" and "Next context item" or "Previous context item",
    silent = true,
  })
end

--DONE
function Context.setup(opts)
  Context.Options = vim.tbl_deep_extend("force", setup.defaults, opts or {})
  diff.setup_diff()
  setup.setup_qf()
  if Context.Options.diagram.enabled then
    setup.setup_diagram_plugins(Context)
  end
  if Context.Options.trouble then
    setup.setup_trouble()
  end
  -- After other startup maps (mini.bracketed) so [q / ]q keep the jump and open the editor.
  vim.schedule(function()
    bind_qf_context("]q", "forward")
    bind_qf_context("[q", "backward")
  end)
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

--DONE
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

  referenceBuffer.on_move = function(on_done)
    utils.transfer_reference(item, "move", on_done)
  end
  referenceBuffer.on_copy = function(on_done)
    utils.transfer_reference(item, "copy", on_done)
  end

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

--DONE
---@param idx? number
function Context.EditReferenceLines(idx)
  if vim.bo.filetype ~= "qf" then
    log.error("EditReferenceLines must be run from the quickfix list")
    return
  end
  utils.edit_reference_lines(idx or vim.fn.line("."))
end

--DONE
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
      utils.confirm_leave_current(function()
        open_context_form(true)
      end)
      return
    end

    local stacked_idx = utils.find_stack_idx_by_id(choice.id)
    if stacked_idx then
      if stacked_idx == 1 and utils.showing_stack_entry(Context.stack[1]) then
        log.info("loaded context: " .. choice.title)
        return
      end
      utils.confirm_leave_current(function()
        utils.activate_idx(stacked_idx, "r")
        log.info("loaded context: " .. choice.title)
      end)
      return
    end

    utils.confirm_leave_current(function()
      local loaded, err = utils.load_as_loaded(choice.id)
      if not loaded then
        log.error("failed to load context" .. tostring(err))
        return
      end
      if loaded.title == "" then
        loaded.title = choice.title
      end
      utils.push_loaded(loaded, " ")
      log.info("loaded context: " .. choice.title)
    end)
  end)
end

--DONE
function Context.DeleteContext()
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
  if not titles or #titles == 0 then
    log.info("no saved contexts")
    return
  end

  vim.ui.select(titles, {
    prompt = "Delete context:",
    format_item = function(item)
      return item.title
    end,
  }, function(choice)
    if not choice then
      return
    end

    vim.ui.select({ "Cancel", "Delete from database" }, {
      prompt = string.format("Delete '%s'? This removes it from the database.", choice.title),
    }, function(confirm)
      if confirm ~= "Delete from database" then
        return
      end

      local del_ok, err = pcall(sql.delete_context, Context.root, choice.id)
      if not del_ok then
        log.error("failed to delete context: " .. tostring(err))
        return
      end

      local stacked_idx = utils.find_stack_idx_by_id(choice.id)
      if stacked_idx then
        local was_current = stacked_idx == 1
        table.remove(Context.stack, stacked_idx)
        if was_current then
          if #Context.stack > 0 then
            utils.activate_idx(1, "r")
          else
            utils.apply_loaded({ title = "", items = {}, context = {} }, "r")
          end
        end
      end

      log.info("deleted context: " .. choice.title)
    end)
  end)
end

--DONE
function Context.PickContext()
  if not Context.stack or #Context.stack == 0 then
    log.info("no loaded contexts")
    return
  end

  vim.ui.select(Context.stack, {
    prompt = "Switch context:",
    format_item = function(item)
      local idx
      for i, entry in ipairs(Context.stack) do
        if entry == item then
          idx = i
          break
        end
      end
      local prefix = idx == 1 and "* " or "  "
      return prefix .. (item.title or "")
    end,
  }, function(choice)
    if not choice then
      return
    end
    local idx
    for i, entry in ipairs(Context.stack) do
      if entry == choice then
        idx = i
        break
      end
    end
    if not idx then
      return
    end
    if idx == 1 and utils.showing_stack_entry(Context.stack[1]) then
      log.info("switched to context: " .. choice.title)
      return
    end
    utils.confirm_leave_current(function()
      utils.activate_idx(idx, "r")
      log.info("switched to context: " .. choice.title)
    end)
  end)
end

--DONE
---@param create boolean
---@param focus_item? vim.quickfix.entry
function open_context_form(create, focus_item)
  if not Context.root then
    Context.root = vim.fs.root(0, ".git")
    if not Context.root then
      log.error("not inside a git repository")
      return
    end
  end

  local title, description = "", ""
  local title_timestamp, title_git_hash, description_timestamp, description_git_hash
  local items = {}
  local creating = { pending = create and true or false }

  if not create then
    local info = vim.fn.getqflist({ title = 0, context = 0, items = 0 })
    local ctx = type(info.context) == "table" and info.context or {}
    if utils.is_flow_view(ctx) then
      log.error("leave the flow view before editing the context")
      return
    end
    title = info.title or ""
    description = ctx.description or ""
    title_timestamp = ctx.title_timestamp
    title_git_hash = ctx.title_git_hash
    description_timestamp = ctx.description_timestamp
    description_git_hash = ctx.description_git_hash
    items = info.items or {}
  end

  local diagram = Context.Options and Context.Options.diagram
  local diagram_enabled = type(diagram) == "table" and diagram.enabled and true or false

  local function apply_result(result)
    if creating.pending then
      utils.push_loaded({
        title = result.title,
        items = {},
        context = {
          type = "context",
          description = result.description,
          title_timestamp = result.title_timestamp,
          title_git_hash = result.title_git_hash,
          description_timestamp = result.description_timestamp,
          description_git_hash = result.description_git_hash,
        },
      }, " ")
      creating.pending = false
      return true
    end

    local fresh = vim.fn.getqflist()
    for _, upd in ipairs(result.item_updates or {}) do
      local idx = utils.find_qf_index(fresh, upd.item)
      if idx then
        local ud = type(fresh[idx].user_data) == "table" and fresh[idx].user_data or {}
        ud.description = upd.description
        if upd.timestamp ~= nil then
          ud.timestamp = upd.timestamp
        end
        if upd.git_hash ~= nil then
          ud.git_hash = upd.git_hash
        end
        fresh[idx].user_data = ud
        if type(upd.item.user_data) == "table" then
          upd.item.user_data.description = upd.description
          upd.item.user_data.timestamp = ud.timestamp
          upd.item.user_data.git_hash = ud.git_hash
        end
      end
    end

    local info = vim.fn.getqflist({ context = 0 })
    local ctx = type(info.context) == "table" and vim.deepcopy(info.context) or {}
    ctx.description = result.description
    ctx.type = utils.list_type(ctx.type)
    ctx.title_timestamp = result.title_timestamp
    ctx.title_git_hash = result.title_git_hash
    ctx.description_timestamp = result.description_timestamp
    ctx.description_git_hash = result.description_git_hash
    vim.fn.setqflist({}, "r", { title = result.title, items = fresh, context = ctx })
    if Context.stack[1] then
      Context.stack[1].title = result.title
    end
    if Context.Options and Context.Options.trouble then
      require("trouble").refresh("qflist")
    end
    return true
  end

  buffer.open_context_editor({
    title = title,
    description = description,
    title_timestamp = title_timestamp,
    title_git_hash = title_git_hash,
    description_timestamp = description_timestamp,
    description_git_hash = description_git_hash,
    items = items,
    focus_item = focus_item,
    diagram_enabled = diagram_enabled,
    diagram_snippets = diagram_enabled and diagram.snippets or nil,
    on_apply = function(result)
      local was_create = creating.pending
      if not apply_result(result) then
        return false
      end
      if was_create then
        log.info("created context " .. result.title)
      else
        log.info("updated context")
      end
      return true
    end,
    on_save = function(result)
      if not apply_result(result) then
        return false
      end
      return Context.SaveContext() == true
    end,
    on_move = function(item, on_done)
      utils.transfer_reference(item, "move", on_done)
    end,
    on_copy = function(item)
      utils.transfer_reference(item, "copy")
    end,
  })
end

function focus_current_qf_item()
  local info = vim.fn.getqflist({ idx = 0, size = 0, context = 0 })
  if info.size == 0 then
    return
  end
  local ctx = type(info.context) == "table" and info.context or {}
  if utils.is_flow_view(ctx) then
    return
  end
  local item = vim.fn.getqflist()[info.idx]
  if not utils.is_context_item(item) then
    return
  end
  if buffer.context_editor_open() then
    buffer.focus_context_item(item)
    return
  end
  open_context_form(false, item)
end

--DONE
function Context.EditContext(arg1, arg2)
  local _, item = utils.resolve_list_item(arg1, arg2)
  open_context_form(false, item)
end

--DONE
function Context.AddEditContextTitle(arg1, arg2)
  Context.EditContext(arg1, arg2)
end

--DONE
function Context.AddFlow()
  local info = vim.fn.getqflist({ context = 0 })
  local context = type(info.context) == "table" and info.context or {}

  vim.ui.input({ prompt = "Flow name: " }, function(name)
    if name == nil or name == "" then
      log.error("flow must have a name")
      return
    end
    local new_context = vim.deepcopy(context)
    local flows = new_context.flows
    if type(flows) ~= "table" then
      flows = {}
    end
    table.insert(flows, { title = name, items = {} })
    new_context.flows = flows
    utils.write_qf_context(new_context)
    log.info("added flow: " .. name)
  end)
end

--DONE
---@param arg1 any
---@param arg2 any
function Context.AddItemToFlow(arg1, arg2)
  local from_trouble_ctx = type(arg1) == "table"
  local in_qf = vim.bo.filetype == "qf"
  local in_trouble = vim.bo.filetype == "trouble" or vim.w.trouble
  if not from_trouble_ctx and not in_qf and not in_trouble then
    log.error("AddItemToFlow must be run from the quickfix or trouble list")
    return
  end

  local endpoints = utils.resolve_flow_endpoints(arg1, arg2)
  if not endpoints then
    log.error("no context reference under cursor")
    return
  end

  local info = vim.fn.getqflist({ context = 0 })
  local context = type(info.context) == "table" and vim.deepcopy(info.context) or {}
  local flows = context.flows
  if type(flows) ~= "table" or #flows == 0 then
    log.info("no flows available")
    return
  end

  ---@param flow ContextFlow
  ---@param pairs_to_add number[][]
  local function add_connections(flow, pairs_to_add)
    flow.items = type(flow.items) == "table" and flow.items or {}
    local added = 0
    local disconnected = 0
    for _, pair in ipairs(pairs_to_add) do
      if pair[1] == pair[2] or utils.connection_exists(flow.items, pair[1], pair[2]) then
        -- skip
      elseif #flow.items > 0 and not utils.flow_has_item(flow, pair[1], pair[1]) then
        disconnected = disconnected + 1
      else
        table.insert(flow.items, { pair[1], pair[2] })
        added = added + 1
      end
    end
    if added == 0 then
      if disconnected > 0 then
        log.error("source is not in flow: " .. (flow.title or ""))
      else
        log.info("connection already in flow: " .. (flow.title or ""))
      end
      return
    end
    utils.write_qf_context(context)
    log.info("added connection to flow: " .. (flow.title or ""))
  end

  vim.ui.select(flows, {
    prompt = "Add connection to flow:",
    format_item = function(flow)
      return flow.title or ""
    end,
  }, function(choice)
    if not choice then
      return
    end
    if #endpoints >= 2 then
      local pairs_to_add = {}
      for i = 1, #endpoints - 1 do
        table.insert(pairs_to_add, { endpoints[i].id, endpoints[i + 1].id })
      end
      add_connections(choice, pairs_to_add)
      return
    end

    local source = endpoints[1]
    choice.items = type(choice.items) == "table" and choice.items or {}
    if #choice.items > 0 and not utils.flow_has_item(choice, source.id, source.idx) then
      log.error("source is not in flow: " .. (choice.title or ""))
      return
    end
    local qflist = vim.fn.getqflist()
    local candidates = {}
    for i, item in ipairs(qflist) do
      if i ~= source.idx then
        table.insert(candidates, { idx = i, item = item, id = utils.item_ref_id(item, i) })
      end
    end
    if #candidates == 0 then
      log.error("need another item to form a connection")
      return
    end
    vim.ui.select(candidates, {
      prompt = "Connect to:",
      format_item = function(entry)
        return utils.format_flow_endpoint(entry.item)
      end,
    }, function(target)
      if not target then
        return
      end
      add_connections(choice, { { source.id, target.id } })
    end)
  end)
end

--DONE
---@param arg1 any
---@param arg2 any
function Context.RemoveItemFromFlow(arg1, arg2)
  local from_trouble_ctx = type(arg1) == "table"
  local in_qf = vim.bo.filetype == "qf"
  local in_trouble = vim.bo.filetype == "trouble" or vim.w.trouble
  if not from_trouble_ctx and not in_qf and not in_trouble then
    log.error("RemoveItemFromFlow must be run from the quickfix or trouble list")
    return
  end

  local idx, item = utils.resolve_list_item(arg1, arg2)
  if not item or not idx then
    log.error("no context reference under cursor")
    return
  end

  local info = vim.fn.getqflist({ context = 0 })
  local context = type(info.context) == "table" and vim.deepcopy(info.context) or {}
  local flows = context.flows
  if type(flows) ~= "table" or #flows == 0 then
    log.info("no flows available")
    return
  end

  local item_id = utils.item_ref_id(item, idx)
  local containing = {}
  for _, flow in ipairs(flows) do
    if utils.flow_has_item(flow, item_id, idx) then
      table.insert(containing, flow)
    end
  end

  if #containing == 0 then
    log.info("item is not in any flow")
    return
  end

  ---@param flow ContextFlow
  local function remove_from(flow)
    local kept = {}
    for _, pair in ipairs(flow.items) do
      if pair[1] ~= item_id and pair[1] ~= idx and pair[2] ~= item_id and pair[2] ~= idx then
        table.insert(kept, pair)
      end
    end
    flow.items = kept
    utils.write_qf_context(context)
    log.info("removed item from flow: " .. (flow.title or ""))
  end

  if #containing == 1 then
    remove_from(containing[1])
    return
  end

  vim.ui.select(containing, {
    prompt = "Remove item from flow:",
    format_item = function(flow)
      return flow.title or ""
    end,
  }, function(choice)
    if not choice then
      return
    end
    remove_from(choice)
  end)
end

--DONE
---@param arg1 any
---@param arg2 any
function Context.ActivateItemFlow(arg1, arg2)
  local from_trouble_ctx = type(arg1) == "table"
  local in_qf = vim.bo.filetype == "qf"
  local in_trouble = vim.bo.filetype == "trouble" or vim.w.trouble
  if not from_trouble_ctx and not in_qf and not in_trouble then
    log.error("ActivateItemFlow must be run from the quickfix or trouble list")
    return
  end

  local idx, item = utils.resolve_list_item(arg1, arg2)
  if not item or not idx then
    log.error("no context reference under cursor")
    return
  end

  local info = vim.fn.getqflist({ context = 0 })
  local context = type(info.context) == "table" and info.context or {}
  local flows = context.flows
  if type(flows) ~= "table" or #flows == 0 then
    log.info("no flows available")
    return
  end

  local item_id = utils.item_ref_id(item, idx)
  local containing = {}
  for _, flow in ipairs(flows) do
    if utils.flow_has_item(flow, item_id, idx) then
      table.insert(containing, flow)
    end
  end

  if #containing == 0 then
    log.info("item is not in any flow")
    return
  end

  if #containing == 1 then
    utils.activate_flow(containing[1])
    return
  end

  vim.ui.select(containing, {
    prompt = "Activate flow:",
    format_item = function(flow)
      return flow.title or ""
    end,
  }, function(choice)
    if not choice then
      return
    end
    utils.activate_flow(choice)
  end)
end

--DONE
function Context.AddEditContextDescription(arg1, arg2)
  Context.EditContext(arg1, arg2)
end

--DONE
function Context.SetContextType()
  local info = vim.fn.getqflist({ context = 0 })
  local context = type(info.context) == "table" and info.context or {}
  local current = utils.list_type(context.type)

  vim.ui.select(STACK_TYPES, {
    prompt = "List type (current: " .. current .. "):",
  }, function(choice)
    if not choice then
      return
    end
    local typ = utils.list_type(choice)
    local new_context = vim.deepcopy(context)
    new_context.type = typ
    vim.fn.setqflist({}, "r", { context = new_context })
    if vim.bo.filetype == "qf" then
      vim.wo.winbar = utils.current_display_title()
    end
    if Context.Options and Context.Options.trouble then
      require("trouble").refresh("qflist")
    end
    log.info("set list type to " .. typ)
  end)
end

--DONE
---@return boolean
function Context.SaveContext()
  if not Context.root then
    Context.root = vim.fs.root(0, ".git")
    if not Context.root then
      log.error("not inside a git repository")
      return false
    end
  end

  ---@type vim.fn.setqflist.what
  local live = vim.fn.getqflist({ context = 0, items = 0, title = 0 })
  local live_ctx = type(live.context) == "table" and live.context or {}
  local viewing_flow = utils.is_flow_view(live_ctx)

  ---@type vim.fn.setqflist.what
  local info = live
  if viewing_flow then
    local parent_ctx
    if utils.flow_parent and type(utils.flow_parent.context) == "table" then
      parent_ctx = vim.deepcopy(utils.flow_parent.context)
    else
      parent_ctx = vim.deepcopy(live_ctx)
    end
    parent_ctx.active_flow = nil
    parent_ctx.flows = live_ctx.flows or parent_ctx.flows or {}
    parent_ctx.id = live_ctx.id or parent_ctx.id or (Context.stack[1] and Context.stack[1].id)
    info = {
      title = (utils.flow_parent and utils.flow_parent.title ~= "" and utils.flow_parent.title)
          or (Context.stack[1] and Context.stack[1].title)
          or "",
      items = utils.flow_parent and utils.flow_parent.items or {},
      context = parent_ctx,
    }
  end

  local title = info.title
  if title == "" or title == nil then
    log.error("set a title for context before saving")
    return false
  end

  local db_id = type(info.context) == "table" and info.context.id or nil

  -- A flow view is not its own list: write flows onto the parent ContextList only.
  if viewing_flow and db_id then
    local ok, err = pcall(
      sql.update_context,
      Context.root,
      {
        id = db_id,
        type = utils.list_type(type(info.context) == "table" and info.context.type),
        flows = live_ctx.flows or {},
        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      },
      {},
      {},
      title,
      nil
    )
    if not ok then
      log.error("failed to update context: " .. tostring(err))
      return false
    end
    if Context.stack[1] then
      Context.stack[1].id = db_id
      Context.stack[1].title = title
    end
    log.info("updated context: " .. title)
    return true
  end

  local previous_ok, previous_context = true, nil
  if db_id then
    previous_ok, previous_context = pcall(sql.load_list, Context.root, db_id)
    if not previous_ok then
      previous_context = nil
    end
  end

  ---@type boolean,boolean,ContextList
  local conv_ok, new, context = pcall(utils.qflist_to_context, info, previous_context)
  if not conv_ok then
    log.error("failed to build context: " .. tostring(context))
    return false
  end

  ---@type ContextItem, UpdateContextItem
  local new_items, updated_items =
      utils.qfitems_to_dbrows(info.items, previous_context and previous_context.items, Context.root)
  local deleted_ids = utils.deleted_item_ids(info.items, previous_context and previous_context.items)

  if new then
    local ok, new_id = pcall(sql.insert_context, Context.root, context, new_items)
    if not ok then
      log.error("failed to save context: " .. tostring(new_id))
      return false
    end
    local saved_ctx
    if viewing_flow then
      saved_ctx = vim.deepcopy(live_ctx)
      saved_ctx.id = new_id
      saved_ctx.flows = context.flows
      if utils.flow_parent and utils.flow_parent.context then
        utils.flow_parent.context.id = new_id
      end
    else
      saved_ctx = type(info.context) == "table" and vim.deepcopy(info.context) or {}
      saved_ctx.id = new_id
    end
    vim.fn.setqflist({}, "r", { context = saved_ctx })
    if Context.stack[1] then
      Context.stack[1].id = new_id
      Context.stack[1].title = title
    else
      table.insert(Context.stack, 1, { id = new_id, title = title })
    end
    log.info("saved context: " .. title)
    return true
  elseif previous_ok then
    local ok, err = pcall(
      sql.update_context,
      Context.root,
      context,
      new_items,
      updated_items,
      previous_context and previous_context.title,
      deleted_ids
    )
    if not ok then
      log.error("failed to update context: " .. tostring(err))
      return false
    end
    if Context.stack[1] then
      Context.stack[1].id = db_id
      Context.stack[1].title = title
    end
    log.info("updated context: " .. title)
    return true
  else
    log.error("failed to load previous context: " .. tostring(previous_context))
    return false
  end
end

--DONE
function Context.ConvertQFlist()
  if not Context.root then
    Context.root = vim.fs.root(0, ".git")
    if not Context.root then
      log.error("not inside a git repository")
      return
    end
  end

  local info = vim.fn.getqflist({ items = 0, title = 0, context = 0 })
  if not info.items or #info.items == 0 then
    log.error("quickfix list is empty")
    return
  end

  local converted, skipped = utils.qflist_to_context_items(info.items)
  if #converted == 0 then
    log.error("no convertible quickfix entries")
    return
  end

  vim.ui.input({ prompt = "Quickfix title: ", default = info.title or "" }, function(title)
    if title == nil or title == "" then
      log.error("context must have title")
      return
    end
    vim.fn.setqflist({}, "r", { items = converted, title = title })
    if Context.Options.trouble then
      require("trouble").refresh("qflist")
    end
    if #Context.stack == 0 then
      utils.adopt_current_qf()
    elseif Context.stack[1] then
      Context.stack[1].title = title
    end
    local msg = "converted " .. #converted .. " quickfix entries"
    if skipped > 0 then
      msg = msg .. " (" .. skipped .. " skipped)"
    end
    log.info(msg)
  end)
end

---@param line1? number
---@param line2? number
--DONE
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
    utils.activate_or_push(item.list_id, function(activate)
      if not activate then
        return
      end
      buffer.open_reference_editor({
        default = item.description,
        code = item.base_text,
        source_buf = bufnr,
        readonly = true,
        diagram_keymap = nil,
        diagram_enabled = Context.Options.diagram.enabled,
        on_move = function(on_done)
          utils.transfer_reference(item, "move", on_done)
        end,
        on_copy = function(on_done)
          utils.transfer_reference(item, "copy", on_done)
        end,
      }, function() end)
    end)
  end, {
    diagram_enabled = Context.Options.diagram.enabled,
    git_root = Context.root,
    on_activate = function(item)
      utils.activate_or_push(item.list_id)
    end,
    on_move = function(item, on_done)
      utils.transfer_reference(item, "move", on_done)
    end,
    on_copy = function(item, on_done)
      utils.transfer_reference(item, "copy", on_done)
    end,
  })
end

--DONE
function Context.StatuslineComponent()
  return {
    function()
      return utils.current_display_title()
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

--DONE
function Context.EditTroubleItemNote(ctx)
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
    Context.EditContext(ctx)
  else
    log.info("trouble not enabled")
  end
end

--DONE
function Context.EditTroubleItemLines(ctx)
  if not (Context.Options and Context.Options.trouble) then
    log.info("trouble not enabled")
    return
  end
  if type(ctx) ~= "table" then
    log.error("no quickfix reference under cursor")
    return
  end

  local raw_item = ctx.item and ctx.item.item
  if not raw_item then
    log.error("no quickfix reference under cursor")
    return
  end

  local idx = utils.find_qf_index(vim.fn.getqflist(), raw_item)
  if not idx then
    log.error("could not locate context reference")
    return
  end
  utils.edit_reference_lines(idx)
end

--DONE
---@param line1? number
function Context.DeleteReference(line1)
  if vim.bo.filetype ~= "qf" then
    log.error("DeleteReference must be run from the quickfix list")
    return
  end
  utils.delete_qf_index(line1 or vim.fn.line("."))
end

--DONE
---@param idx? number
function Context.MoveReference(idx)
  utils.transfer_qf_reference(idx, "move")
end

--DONE
---@param idx? number
function Context.CopyReference(idx)
  utils.transfer_qf_reference(idx, "copy")
end

--DONE
function Context.ToggleQfDiff()
  local on = require("nvim-context.qf").toggle()
  if on then
    log.info("qf jump diff on")
  else
    log.info("qf jump diff off")
  end
end

--DONE
function Context.ToggleQfViewer()
  local on = require("nvim-context.qf").toggle_viewer()
  if on then
    log.info("qf reference viewer on")
  else
    log.info("qf reference viewer off")
  end
end

--DONE
function Context.DeleteTroubleItem(ctx)
  if not (Context.Options and Context.Options.trouble) then
    log.info("trouble not enabled")
    return
  end

  local raw_item = ctx and ctx.item and ctx.item.item
  if not raw_item then
    log.error("no quickfix reference under cursor")
    return
  end

  local idx = utils.find_qf_index(vim.fn.getqflist(), raw_item)
  if not idx then
    log.error("could not locate context reference")
    return
  end
  utils.delete_qf_index(idx)
end

return Context
