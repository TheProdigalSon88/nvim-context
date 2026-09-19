# nvim-context

Pin code ranges, write markdown notes against them, and persist named **contexts**
per git repository. The working set is the **quickfix list**; the database is just
how you keep it.

Works only inside a git repo. Notes and ranges are stored at
`<git-root>/.nvim-context/context.db` (keep that directory gitignored).

## Features

- Capture a visual range (or the current line) as a **reference** with a markdown note
- Live working state is the quickfix list — title is the context name
- Save, load, and delete named contexts in a per-repo SQLite database
- Keep several contexts loaded and switch between them
- Find every saved note that covers the cursor (`ShowReference`)
- Highlight ranges that drifted from the captured snapshot (git-aware)
- Optional [Trouble](https://github.com/folke/trouble.nvim) list/preview marks
- Optional Mermaid diagrams in notes via [image.nvim](https://github.com/3rd/image.nvim)
  and [diagram.nvim](https://github.com/3rd/diagram.nvim)
- Optional statusline component (lualine-shaped)

## Requirements

- Neovim 0.10+
- A git working tree (`vim.fs.root(0, ".git")` must succeed)
- [kkharji/sqlite.lua](https://github.com/kkharji/sqlite.lua)

Optional:

- [folke/trouble.nvim](https://github.com/folke/trouble.nvim) — `trouble = true`
- [3rd/image.nvim](https://github.com/3rd/image.nvim) + [3rd/diagram.nvim](https://github.com/3rd/diagram.nvim) — `diagram.enabled = true`
- A statusline plugin that accepts a `{ fn, cond }` component (lualine, etc.)

## Installation

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
   "TheProdigalSon88/nvim-context",
   dependencies = { "kkharji/sqlite.lua" },
   opts = {}, -- calls setup(); see Configuration
}
```

`setup()` turns on jump-diff highlights and the quickfix follow-viewer. Commands
exist without it (`:Context …` is registered from `plugin/`), but you almost
always want `setup()`.

Add `.nvim-context/` to the **project** gitignore so the database is not committed.

## Quick start

Suggested keymaps (visual `AddReference` should call Lua so the selection is
still active — `:Context AddReference` from the command line is already out of
visual mode and would capture only the current line):

```lua
local context = require("nvim-context")

vim.keymap.set({ "n", "v" }, "<leader>ca", context.AddReference, { desc = "Context: add reference" })
vim.keymap.set("n", "<leader>cl", context.LoadContext, { desc = "Context: load" })
vim.keymap.set("n", "<leader>cs", context.SaveContext, { desc = "Context: save" })
vim.keymap.set("n", "<leader>cp", context.PickContext, { desc = "Context: pick loaded" })
vim.keymap.set("n", "<leader>cr", context.ShowReference, { desc = "Context: show at cursor" })
vim.keymap.set("v", "<leader>cr", ":Context ShowReference<CR>", { desc = "Context: show in range" })
```

Typical loop:

1. Open a file in a git repo.
2. Visual-select a range (or sit on a line) and add a reference.
3. Write the note **above** `## Associated Code`. `:w` saves the note and appends
   the item to the quickfix list. `q` closes without saving.
4. Give the list a title (`:Context AddEditContextTitle`) if you created it by
   adding items rather than `:Context LoadContext` → *+ New Context*.
5. `:Context SaveContext`.
6. Later, `:Context LoadContext` to bring it back.

## Commands

All public functions on `require("nvim-context")` are subcommands:

```
:Context <Subcommand>
```

| Command | Where | What it does |
| --- | --- | --- |
| `AddReference` | source buffer | Capture the visual range or current line, open the note editor, append to the qflist on `:w` |
| `EditReference` | quickfix | Edit the note for the item under the cursor |
| `EditReferenceLines` | quickfix | Jump to the source, reselect the range; `<CR>` in visual mode commits, `<Esc>` cancels |
| `DeleteReference` | quickfix | Remove the item under the cursor (not yet deleted from the DB until you save) |
| `MoveReference` | quickfix | Move the item to another **loaded** context |
| `CopyReference` | quickfix | Copy the item to another **loaded** context |
| `LoadContext` | anywhere | Pick a saved context, or *+ New Context* |
| `SaveContext` | anywhere | Persist the current qflist (a title is required) |
| `DeleteContext` | anywhere | Delete a saved context from the database |
| `PickContext` | anywhere | Switch among contexts already loaded in this session |
| `AddEditContextTitle` | anywhere | Set / change the qflist title (context name) |
| `AddEditContextDescription` | anywhere | Markdown description for the whole context |
| `ConvertQFlist` | anywhere | Turn a normal qflist (grep, lsp, …) into context items |
| `ShowReference` | source buffer | Notes whose ranges cover the cursor; accepts a visual/command range |
| `ToggleQfDiff` | anywhere | Toggle stale-range highlights when jumping from the qflist |
| `ToggleQfViewer` | anywhere | Toggle the follow-split that shows the current qf item's note |

Tab-completes on subcommand names.

### Trouble-only helpers

These take a Trouble `ctx`, not a command range. **Do not** invoke them via
`:Context …` — bind them on the Trouble qflist view:

```lua
-- inside trouble.nvim keys for mode "qflist"
["<leader>cn"] = {
   action = function(ctx)
      require("nvim-context").EditTroubleItemNote(ctx)
   end,
   desc = "Edit context note",
},
["<leader>ce"] = {
   action = function(ctx)
      require("nvim-context").EditTroubleItemLines(ctx)
   end,
   desc = "Edit context lines",
},
["d"] = {
   action = function(ctx)
      require("nvim-context").DeleteTroubleItem(ctx)
   end,
   desc = "Delete context item",
},
```

## Buffers and keymaps

The plugin opens scratch markdown buffers. Bindings are buffer-local; the winbar
lists the ones that apply.

### Note editor (`AddReference`, `EditReference`, context description)

Write above `## Associated Code`. The fenced code block is the captured snapshot.

| Key | Action |
| --- | --- |
| `:w` | Save the note (text above `## Associated Code`) |
| `q` | Close without saving / pop back |
| `m` | Move this item to another loaded context (when editing an existing item) |
| `c` | Copy this item to another loaded context |

Closing the window without `:w` discards the edit.

### Reference viewer (`ShowReference`)

One section per matching note (timestamp + parent context title, description,
captured code). Default sort is **containment** (innermost range first); `s`
toggles to latest timestamp.

| Key | Action |
| --- | --- |
| `<CR>` | Activate that item's context and open its note |
| `a` | Activate the parent context without leaving the viewer |
| `s` | Toggle sort: containment ↔ timestamp |
| `m` / `c` | Move / copy the section under the cursor |
| `q` | Close / pop back |

Moving the cursor previews the range in the source window and marks git drift.

### Quickfix follow-viewer

After `setup()`, a `winfixbuf` split follows the current qflist item so `:cnext`
does not steal the window. `q` closes it (and turns the follow-viewer off until
`:Context ToggleQfViewer`).

## Stale ranges

Each reference stores `base_text` and the git hash at capture time. When the
working tree no longer matches that snapshot, nvim-context paints the drift:

- In the source buffer after a qflist jump (`ToggleQfDiff`)
- In the `ShowReference` viewer (and on the source range under the cursor)
- In Trouble's qflist rows and preview, if `trouble = true`

Items without a `git_hash` are skipped. Highlight group: `NvimContextChanged`
(links to `MiniDiffOverDelete` when present, otherwise `DiffDelete`).

## Configuration

```lua
require("nvim-context").setup({
   trouble = false, -- patch trouble.sources.qf.preview + refresh after mutations
   statusline = false, -- enable StatuslineComponent()
   diagram = {
      enabled = false,
      -- keymap string → mermaid diagram type (note editor only)
      snippets = {
         -- ["<leader>mf"] = "flowchart",
         -- ["<leader>ms"] = "sequenceDiagram",
         -- ["<leader>mc"] = "classDiagram",
         -- ["<leader>me"] = "erDiagram",
         -- ["<leader>mt"] = "stateDiagram",
         -- ["<leader>mg"] = "gantt",
      },
      image = { backend = "kitty" }, -- passed to image.nvim setup()
      -- integrations = { require("diagram.integrations.markdown") },
      renderer_options = {
         mermaid = { theme = "default" },
      },
   },
})
```

When `diagram.enabled` is true, this plugin calls `image.setup` and
`diagram.setup` for you. Snippet keys insert a fenced `mermaid` block of that
type in the note editor.

### Statusline

lualine (or anything that understands `{ function, cond }`):

```lua
require("lualine").setup({
   sections = {
      lualine_c = {
         "filename",
         require("nvim-context").StatuslineComponent(),
      },
   },
})
```

Shows the current qflist title when `statusline = true` and the title is non-empty.

### Trouble

```lua
require("nvim-context").setup({ trouble = true })
```

Patches `trouble.sources.qf.preview` so stale context items get the same range
diff as a qflist jump, and highlights changed rows in the Trouble list.

## Persistence

| | |
| --- | --- |
| Location | `<git-root>/.nvim-context/context.db` |
| Unique key | `(root, title)` — titles are unique per repo |
| Filenames | Stored git-root-relative, re-expanded on load |
| Unsaved items | `user_data.id == nil` until a successful save + reload |

Loaded contexts live in an in-memory stack. Switching snapshots the current
qflist into the previous active entry first. Move/copy update stack entries in
memory; `:Context SaveContext` while that context is active writes them out.

`ConvertQFlist` is the bridge from grep/lsp/diagnostics lists: it snapshots each
entry's current text and git hash so they behave like native references.

## License

[MIT](LICENSE)
