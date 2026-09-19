# AGENTS.md

Neovim plugin (pure Lua, no build, no tests, no CI). Annotates code ranges, holds them in the quickfix list, and persists named "contexts" to a per-repo SQLite DB.

## Commands

- Format: `stylua lua/ plugin/` — `stylua.toml` is **3-space indent**, 120 cols. `lua/nvim-context/sql.lua` is still 2-space; do not drive-by reindent it.
- No test suite. Verify in Neovim (e.g. `:Context AddReference`).

## Architecture

- `plugin/nvim-context.lua` defines `:Context <Subcommand>` only — it does **not** call `setup()`. It dispatches **by name** to any function on the `Context` table in `lua/nvim-context/init.lua` and calls it with `(line1, line2)` from the command range. A public `Context.Foo` is a subcommand — keep helpers `local` or in other modules.
- Trouble helpers (`EditTroubleItemNote`, `EditTroubleItemLines`, `DeleteTroubleItem`) take a trouble `ctx` (`ctx.item.item`), not the command range. Invoking them via `:Context` passes `(line1, line2)` and they fail.
- Live working state is the **quickfix list**. Persistence metadata is each entry's `user_data` (`UserData`: id, description, base_text, display_text, git_hash, timestamp). `user_data.id == nil` means not yet in the DB; `SaveContext` / `utils.qfitems_to_dbrows` use that to split inserts vs updates. Copy/move clones also clear `id`. After a first save, only `qf.context.id` (list id) is written back — **item** ids are not stamped onto the qflist until reload, so a second save without reload treats every item as new (deletes previous rows, re-inserts).
- QF title = context title. QF `context.id` / `context.description` = DB list id and description.
- `Context.stack` + `Context.active_idx` hold loaded contexts in memory. Activating moves the entry to index 1 and replaces the qflist (`apply_loaded` uses `" "` for a new list, `"r"` to replace). Switching **snapshots** the current qflist into the previous active entry first. Move/copy mutates stack entries in memory; persist with `SaveContext` while that context is active.
- `lua/nvim-context/sql.lua` writes `<git root>/.nvim-context/context.db` via kkharji/sqlite.lua (`require("sqlite")`, lazy). One cached handle per git root. The schema DSL cannot express multi-column UNIQUE, so `UNIQUE(root, title)` is a raw `CREATE UNIQUE INDEX`. sqlite.lua auto-alter cannot add columns; `lists.flows` / `lists.structures` (JSON) are added with raw `ALTER TABLE` for existing DBs.
- **sqlite.lua `pvalues()` trap:** `d.items:insert()` splices strings matching `^[%S]+%(.*%)$` into SQL instead of binding them. Code in `base_text` / `display_text` will syntax-error. Always `d:eval()` with named binds for item rows (see the comment on `insert_items`).
- `caching.lua` is process-local. `load_list` keys `Context:<root>:<id>`; title listing keys `titles:<root>`. Write paths must invalidate the id key. `insert_context` only invalidates titles plus an unused title-keyed key.
- `types.lua` is LuaCATS only — no runtime code.
- Optional `setup()` opts: `trouble` (patches `trouble.sources.qf.preview`, refresh after mutations), `statusline` (lualine-shaped `StatuslineComponent`), `diagram` (when `enabled`, this plugin calls `image.setup` + `diagram.setup`). `qf.setup()` (from `setup()`) enables **both** jump-diff highlights and the qf follow-viewer; `ToggleQfDiff` / `ToggleQfViewer` flip them independently.

## Gotchas

- Entry points lazily set `Context.root` via `vim.fs.root(0, ".git")` and error outside a git repo. `Context.root` is **never re-resolved** later in the session.
- DB filenames are **git-root-relative** and re-expanded on load (`utils.get_file_path` / `utils.dbrows_to_qfitems`).
- User-facing messages go through `lua/nvim-context/log.lua`. Do not copy the raw `vim.notify` in the dispatcher or `utils.git_hash`.
- `.nvim-context/` (including `context.db`) is gitignored — never commit it.
- `buffer.open_reference_editor` is an `acwrite` markdown scratch buffer. Description is everything above `## Associated Code`, captured on `:w` (`BufWriteCmd`). Close without write → callback `nil`. A `done` flag blocks double-fire when `:w` also triggers `BufWinLeave`. Viewer/editor share a per-window buffer stack (`q` pops). QF follow (`buffer.show_qf_follow`) is a separate `winfixbuf` split so `:cnext` does not steal it.
- `Context.Options` is nil until `setup()`. Unguarded `Context.Options.diagram.enabled` / `.trouble` errors. Several older commands (`AddReference`, `EditReference`, title/description editors, `ConvertQFlist`, `ShowReference`) are unguarded; newer mutation paths use `Context.Options and ...`.
- The `FileType qf` winbar autocmd is registered at **module load**, not inside `setup()`.
- `dbrows_to_qfitems` overwrites `user_data.timestamp` with `os.date(...)` (drops the DB value). `sql.load_list` / `get_items_at_line` keep the stored timestamp — qf vs viewer paths disagree.
- `utils.is_context_item` requires a non-empty `user_data.git_hash`; qf/trouble diff highlights skip items without it.
- `utils.range_diff`: compare `git show <hash>:<path>` vs the current file; if the current range still matches captured `base_text`, it is not stale.
- `ContextItem.labels` and `ReferenceBuffer.diagram_keymap` are declared/passed but unused. Mermaid insertion uses `diagram_snippets`.
- `qflist_to_context` never copies `flows` / `structures`, so `SaveContext` does not persist them. `sql.update_context` assigns `structures` onto `set.flows` (copy-paste) — do not cargo-cult that.
