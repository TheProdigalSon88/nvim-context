# AGENTS.md

Neovim plugin (pure Lua, no build step, no tests, no CI). Lets users annotate
code locations, manage them via the quickfix list, and persist named "contexts"
to a per-repo SQLite database.

## Commands

- Format: `stylua lua/ plugin/` — config in `stylua.toml`: **3-space indent**, 120 column width.
- No test suite. Verify changes manually inside Neovim (e.g. `:Context AddReference`).

## Architecture

- `plugin/nvim-context.lua` defines one user command, `:Context <Subcommand>`,
  which dispatches **by name** to any function on the `Context` table from
  `lua/nvim-context/init.lua` and calls it **with two args** (`line1, line2` from
  the command range). Every public function on `Context` automatically becomes a
  subcommand — keep helpers local or in other modules.
- The live working state is the quickfix list. Persistence metadata rides in
  each qf entry's `user_data` (`UserData`: id, description, base_text,
  display_text, git_hash, timestamp). `id == nil` means "not yet in DB" —
  `SaveContext` uses this to split new vs. updated rows (`utils.qfitems_to_dbrows`).
- The DB list id is stored in the quickfix *context*
  (`getqflist({context=0}).context.id`); title lives in the qf title.
- `lua/nvim-context/sql.lua` persists to `<git root>/.nvim-context/context.db`
  via kkharji/sqlite.lua (`require("sqlite")`, required lazily). One cached DB
  handle per git root. The schema DSL can't express multi-column UNIQUE, so
  `UNIQUE(root, title)` is enforced with a raw `CREATE UNIQUE INDEX` eval.
- `lua/nvim-context/caching.lua` is a plain in-memory cache used by sql.lua for
  titles (`titles:<root>`) and loaded contexts (`Context:<root>:<id>`). Any
  write path must invalidate the matching keys or reads go stale.
- `lua/nvim-context/types.lua` is LuaCATS annotations only — no runtime code.
- Optional integrations gated by `setup()` opts: `trouble` (refresh qflist
  view after mutations), `statusline` (`StatuslineComponent` is a lualine-shaped
  component), and `diagram` (`{ enabled, snippets }` for diagram.nvim).

## Gotchas

- All entry points lazily resolve `Context.root` via `vim.fs.root(0, ".git")`
  and error outside a git repo; new commands should follow the same pattern.
  `Context.root` is module-level and session-persistent — it is never re-checked
  after the first resolution.
- File paths are stored in the DB **relative to the git root** and re-expanded
  on load (`utils.get_file_path` / `utils.dbrows_to_qfitems`).
- User feedback goes through `lua/nvim-context/log.lua` (`log.info`/`log.error`),
  not raw `vim.notify`. Exceptions: the dispatcher (`plugin/nvim-context.lua`)
  and `utils.git_hash` currently use raw `vim.notify` — don't copy that pattern.
- `.nvim-context/` (this repo's own plugin data, incl. `context.db`) is
  gitignored — never commit it.
- `buffer.open_note_editor` opens an `acwrite` scratch buffer; the description
  is everything above the `## Associated Code` delimiter, captured on `:w`
  (BufWriteCmd). Closing without writing invokes the callback with `nil`. A
  `done` guard prevents double-invocation when `:w` closes the window and
  triggers `BufWinLeave`.
- Cache key mismatch: `sql.insert_context`/`update_context` invalidate
  `"Context:<root>:<title>"` (title string), but `sql.load_list` caches under
  `"Context:<root>:<id>"` (numeric id). These are different keys — post-save
  loads from the id-keyed cache will be stale until the Neovim session restarts.
  Keep this asymmetry in mind when touching cache invalidation logic.
- `Context.Options` must not be `nil` when subcommands run — if `setup()` is
  never called, accessing `Context.Options.diagram.enabled` will error. New
  commands that read options should guard or ensure `setup()` is called first.
- The `FileType qf` autocmd (sets qf `winbar` to context title) is registered
  at module load time, not inside `setup()`.
- `dbrows_to_qfitems` reconstructs `user_data.timestamp` as the current time
  (`os.date(...)`), discarding the stored DB timestamp — known bug.
- `ContextItem.labels` is declared in `types.lua` but unused in the current
  implementation.
- `ReferenceBuffer.diagram_keymap` is declared in `types.lua` and passed from
  `init.lua` but not consumed by `buffer.open_note_editor` — vestigial field.
