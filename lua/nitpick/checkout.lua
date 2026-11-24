-- The local checkout: which repo a path or buffer is in, and its branch and commit under git or jj.

local async = require("nitpick.async")

local M = {}

--- Markers that make a directory a repo root. `.jj` comes first in spirit, not
--- in precedence: vim.fs.root takes the nearest directory holding any marker.
--- A secondary jj workspace has a `.jj` but no `.git`; matching only `.git`
--- would walk up to the main workspace and read its branch instead.
M.root_markers = { ".jj", ".git" }

--- Normalized repo toplevel containing `path` (a path or buffer number), or nil.
---@param path string|integer
---@return string?
function M.repo_root(path)
  local root = vim.fs.root(path, M.root_markers)
  return root and vim.fs.normalize(root) or nil
end

--- Normalized repo toplevel for the current buffer. nil outside a repo.
---@return string?
function M.current_root()
  return M.repo_root(0)
end

--- Normalized repo toplevel containing a buffer's file, or nil. Unnamed buffers
--- resolve to nil on purpose — a scratch buffer belongs to no repo, so falling
--- back to the cwd would render another repo's comments in it.
---@param buf integer
---@return string?
function M.buf_root(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return nil
  end
  return M.repo_root(name)
end

--- Normalized repo root containing the cwd, or nil. The toggle/statusline
--- anchor: mirrors how triage scopes review mode, so "this tab's repo" means
--- the same thing to both plugins.
---@return string?
function M.cwd_root()
  return M.repo_root(vim.fn.getcwd())
end

--- Is `path` equal to or under `root` (both normalized)?
---@param path string
---@param root string
---@return boolean
function M.under(path, root)
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

--- A buffer's path relative to `root`, or nil if it's not under it.
---@param buf integer
---@param root string
---@return string?
function M.rel_of(buf, root)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return nil
  end
  name = vim.fs.normalize(name)
  if name ~= root and name:sub(1, #root + 1) ~= root .. "/" then
    return nil
  end
  return name:sub(#root + 2)
end

--- First non-empty line of jj's bookmark listing, or "" when there is none.
---@param stdout string
---@return string
function M.first_bookmark(stdout)
  for line in (stdout or ""):gmatch("[^\n]+") do
    line = vim.trim(line)
    if line ~= "" then
      return line
    end
  end
  return ""
end

--- The branch name GitHub knows this checkout by. Under git that is the
--- checked-out branch. In a colocated jj repo HEAD is always detached, so ask jj
--- for the nearest bookmark at or below `@` instead: the working copy is usually
--- an empty, unbookmarked change on top of the pushed one. Runs with
--- --ignore-working-copy so a background lookup never snapshots the files.
--- Returns "" when nothing names the checkout. Must run inside a coroutine.
---@param root string
---@return string
function M.current_branch(root)
  if vim.uv.fs_stat(root .. "/.jj") then
    local obj = async.sh({
      "jj", "--ignore-working-copy", "--color=never", "--no-pager", "-R", root,
      "log", "--no-graph", "-r", "heads(::@ & bookmarks())",
      "-T", 'local_bookmarks.map(|b| b.name()).join("\n") ++ "\n"',
    })
    if obj.code ~= 0 then
      return ""
    end
    return M.first_bookmark(obj.stdout)
  end
  return vim.trim(async.sh({ "git", "-C", root, "branch", "--show-current" }).stdout or "")
end

--- The commit a submitted review is anchored to: what the drafts were placed
--- against. Under git that is HEAD. In a jj workspace ask jj instead -- a
--- secondary workspace has no .git, so git cannot answer there at all. The
--- working copy `@` is usually an empty change on top of the pushed one, so an
--- empty `@` resolves to its parent; a non-empty `@` is the content the drafts
--- describe and is returned as-is (GitHub then 422s until it is pushed, which is
--- the intended recovery -- see nitpick.submit). Returns "" when nothing resolves.
--- Must run inside a coroutine.
---@param root string
---@return string
function M.head_commit(root)
  if vim.uv.fs_stat(root .. "/.jj") then
    local obj = async.sh({
      "jj", "--ignore-working-copy", "--color=never", "--no-pager", "-R", root,
      "log", "--no-graph", "-r", "@",
      "-T", 'if(empty, parents.map(|c| c.commit_id()).join(""), commit_id)',
    })
    if obj.code ~= 0 then
      return ""
    end
    return vim.trim(obj.stdout or "")
  end
  return vim.trim(async.sh({ "git", "-C", root, "rev-parse", "HEAD" }).stdout or "")
end

return M
