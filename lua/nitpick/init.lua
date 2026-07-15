-- nitpick.nvim — GitHub PR line comments, in your normal file buffers.
--
-- While reviewing a file you've actually got open, drop a comment on the line
-- under the cursor (or a visual range). Comments queue as *local drafts* rather
-- than posting one-by-one, so a whole pass goes out as a single GitHub review
-- instead of spraying a notification per line. Submit (<leader>rS) sends every
-- draft in one review; the verdict (approve / request-changes / comment) comes
-- from an injected status source (opts.verdict) — in this config wired to
-- triage.nvim's verdict, but any fun():event will do, and with none configured
-- the user is prompted. Submitting is cheap and repeatable — while triage's
-- verdict reads as mid-review, an early, partial submit goes out as a plain
-- COMMENT batch.
--
-- nitpick knows nothing about triage.nvim: the only link is the opts.verdict
-- callback, so the two can be used together, apart, or the comment backend
-- swapped (GitLab, a file, email) without touching this module.
--
-- Replies and edits to *live* (already-posted) comments still go out
-- immediately — they're rare and not the source of spam. Edit is draft-aware:
-- on a line carrying a draft it edits the draft locally; on your own live
-- comment it PATCHes GitHub; if both are present it asks which.
--
-- Everyone's line comments render inline as virtual text, shown/hidden with
-- review mode; your unsent drafts render alongside them in a dimmer hue. Two
-- categories are noisy, so they're filtered at render time behind toggles
-- (M.show_outdated / M.show_resolved, and the tree icon follows suit): comments
-- GitHub no longer anchors (its `line` nulled — "outdated"), shown by default and
-- tagged; and comments in resolved threads (see review_threads), hidden by
-- default. Both are still fetched, so toggling either needs no round-trip. A
-- thread can be resolved/unresolved in place (<leader>rk) via GraphQL.
--
-- GitHub anchors `line` to the PR-head commit (c.commit_id), but your working
-- copy has local edits and unpushed commits, so that number drifts. We fetch the
-- file blob at c.commit_id (cached — the sha is immutable) and diff it against the
-- live buffer at render time, remapping each anchor through the hunks: a comment
-- whose earlier lines shifted moves silently to track them; one whose own line
-- changed or vanished locally can't be tracked, so it renders near the new hunk
-- and is tagged "drifted". See remap_line / M.base_blob.
--
-- The PR is found from the active branch: none -> stay quiet; one -> use it;
-- several -> ask once (remembered per branch). Rendering reads a cache, so only
-- an explicit refresh or turning review mode on hits the network.

local M = {}

-- User configuration, populated by M.setup(). See setup() for accepted keys.
M.opts = {}

-- rel path -> list of raw review-comment objects from the GitHub API.
M.by_path = {}
-- rel path -> list of unsent draft comments { line, side, start_line?, body }.
-- Loaded from disk per repo; M.drafts_root records which repo they're for.
M.drafts = {}
M.drafts_root = nil
-- Repo toplevel, set whenever we resolve one.
M.root = nil
-- Remembers a manual PR choice for a branch so we don't re-prompt: {branch, number}.
M.pr_choice = nil
-- The authenticated GitHub login, cached; used to find your own comments to edit.
M.viewer = nil
-- login -> resolved display name, cached in-memory. "" means "resolved, but no
-- display name set" (fall back to @login); nil means "not looked up yet".
M.names = {}
-- Whether inline comments are currently drawn (driven by review mode).
M.shown = false
-- Visibility toggles. Both outdated and resolved comments are kept in M.by_path
-- and filtered at render time, so toggling either needs no re-fetch. Outdated
-- shows by default (surfacing stale-line comments is the point); resolved hides
-- by default (a resolved thread no longer wants attention).
M.show_outdated = true
M.show_resolved = false
-- Absolute paths of files with comments or drafts, plus their ancestor dirs, for
-- the tree decorator. Rebuilt on each fetch; empty while comments are hidden.
M.marked = {}
-- "<commit_id>:<rel path>" -> file text at that commit (or false if it couldn't
-- be read). Base for the working-copy remap; keyed by sha so it survives edits
-- and only grows.
M.base_blob = {}

local ns = vim.api.nvim_create_namespace("review_comments")

--- Normalize a value decoded from gh JSON: JSON null arrives as vim.NIL (a
--- truthy userdata, not nil), so `x or fallback` never falls through without
--- this. Returns nil for both nil and vim.NIL, else the value unchanged.
local function val(x)
  if x == nil or x == vim.NIL then
    return nil
  end
  return x
end

--- Whether a live comment should render, given the visibility toggles. A comment
--- is outdated when GitHub has nulled its `line` (anchor no longer exists).
---@param c table
---@return boolean
local function comment_visible(c)
  if c.resolved and not M.show_resolved then
    return false
  end
  if val(c.line) == nil and not M.show_outdated then
    return false
  end
  return true
end

--- Remap a 1-based line number from a base file to its position in an edited
--- version, given the change hunks between them (vim.diff `result_type="indices"`
--- tuples: {start_a, count_a, start_b, count_b}, ascending by start_a). A line
--- untouched by the edit moves by the net insert/delete of the hunks before it; a
--- line whose own text was changed or removed can't be tracked, so we hand back
--- the new hunk's start and false so the caller can flag it.
---@param hunks integer[][]
---@param old_line integer line number in the base file
---@return integer row, boolean tracked (false == line changed/removed here)
function M.remap_line(hunks, old_line)
  local delta = 0
  for _, h in ipairs(hunks) do
    local start_a, count_a, start_b, count_b = h[1], h[2], h[3], h[4]
    if count_a == 0 then
      -- Pure insertion after base line start_a: shifts base lines past it down.
      if start_a < old_line then
        delta = delta + count_b
      else
        break -- this hunk and every later one sit at/after old_line
      end
    else
      local last_a = start_a + count_a - 1 -- last base line the hunk changed
      if old_line < start_a then
        break
      elseif old_line <= last_a then
        return math.max(1, start_b), false -- old_line's text changed/removed
      else
        delta = delta + (count_b - count_a)
      end
    end
  end
  return old_line + delta, true
end

--- Run a command async, yielding until it exits. Returns the vim.system result
--- object ({ code, stdout, stderr }). MUST run inside a coroutine. `stdin`, when
--- given, is fed to the process's stdin (used to POST a review payload as JSON).
---@param cmd string[]
---@param cwd string?
---@param stdin string?
local function sh(cmd, cwd, stdin)
  local co = assert(coroutine.running(), "nitpick: must run inside a coroutine")
  vim.system(cmd, { text = true, cwd = cwd, stdin = stdin }, function(obj)
    vim.schedule(function()
      coroutine.resume(co, obj)
    end)
  end)
  return coroutine.yield()
end

--- Run gh and JSON-decode stdout. Returns (value, nil) or (nil, errmsg).
---@param args string[]
---@param cwd string?
local function gh_json(args, cwd)
  local obj = sh(vim.list_extend({ "gh" }, args), cwd)
  if obj.code ~= 0 then
    return nil, (obj.stderr ~= "" and obj.stderr or "gh exited " .. obj.code)
  end
  local ok, decoded = pcall(vim.json.decode, obj.stdout)
  if not ok then
    return nil, "could not parse gh JSON"
  end
  return decoded
end

--- A short, single-line summary of a failed gh call, safe to notify without
--- tripping the "Press ENTER to continue" prompt. Prefers the API error's
--- "message" field when the body is JSON; otherwise collapses stderr/stdout to
--- one line and truncates.
---@param obj table vim.system result ({ code, stdout, stderr })
---@return string
local function gh_error(obj)
  for _, s in ipairs({ obj.stderr, obj.stdout }) do
    if s and s ~= "" then
      local ok, decoded = pcall(vim.json.decode, s)
      if ok and type(decoded) == "table" and type(decoded.message) == "string" then
        return decoded.message
      end
    end
  end
  local msg = (obj.stderr and obj.stderr ~= "" and obj.stderr) or obj.stdout or ""
  msg = vim.trim(msg:gsub("%s+", " "))
  if msg == "" then
    msg = "gh error"
  end
  return (#msg > 200) and (msg:sub(1, 200) .. "…") or msg
end

--- Drive an async body on a coroutine, surfacing errors as a notification.
---@param fn fun()
local function run(fn)
  coroutine.wrap(function()
    local ok, err = pcall(fn)
    if not ok then
      vim.notify("nitpick: " .. tostring(err), vim.log.levels.ERROR)
    end
  end)()
end

--- vim.ui.select as a coroutine call. Returns the chosen 1-based index, or nil.
--- Handles both the async pickers (snacks: callback fires later, so
--- we yield and resume) and Neovim's builtin select (callback fires *before*
--- vim.ui.select returns — resuming a still-running coroutine would error, so we
--- just hand back the answer directly).
---@param items string[]
---@param opts table
local function pick(items, opts)
  local co = coroutine.running()
  local answered, answer = false, nil
  vim.ui.select(items, opts, function(_, idx)
    answered, answer = true, idx
    if coroutine.status(co) == "suspended" then
      coroutine.resume(co, idx)
    end
  end)
  if answered then
    return answer
  end
  return coroutine.yield()
end

--- Repo toplevel for the current buffer (cached on M.root). nil outside a repo.
---@return string?
local function current_root()
  local root = vim.fs.root(0, ".git")
  M.root = root and vim.fs.normalize(root) or M.root
  return root and vim.fs.normalize(root) or nil
end

--- A buffer's path relative to `root`, or nil if it's not under it.
---@param buf integer
---@param root string
---@return string?
local function rel_of(buf, root)
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

-- ---------------------------------------------------------------------------
-- Draft persistence (per repo, under stdpath("state")/review/<key>.drafts).
-- Drafts hold multi-line bodies, so unlike the triage ledger they're stored as
-- JSON: an object of rel-path -> array of { line, side, start_line?, body }.
-- ---------------------------------------------------------------------------

local function state_dir()
  local dir = vim.fn.stdpath("state") .. "/review"
  vim.fn.mkdir(dir, "p")
  return dir
end

---@param root string
---@return string
local function drafts_file(root)
  local key = root:gsub("[/\\:]", "%%")
  return state_dir() .. "/" .. key .. ".drafts"
end

---@param root string
---@return table<string, table[]>
local function load_drafts(root)
  local path = drafts_file(root)
  if vim.fn.filereadable(path) == 0 then
    return {}
  end
  local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  if not ok or type(data) ~= "table" then
    return {}
  end
  return data
end

---@param root string
local function save_drafts(root)
  local path = drafts_file(root)
  if not next(M.drafts) then
    -- Nothing left: drop the file rather than leave an empty object behind.
    if vim.fn.filereadable(path) == 1 then
      vim.fn.delete(path)
    end
    return
  end
  vim.fn.writefile({ vim.json.encode(M.drafts) }, path)
end

--- Ensure M.drafts is the on-disk draft set for `root` (reloads on repo change).
---@param root string
local function ensure_drafts(root)
  if M.drafts_root == root then
    return
  end
  M.drafts = load_drafts(root)
  M.drafts_root = root
end

--- Add `abs` and every ancestor dir up to the repo root into `marked`.
---@param marked table<string, boolean>
---@param nroot string normalized repo root
---@param rel string
local function mark_with_ancestors(marked, nroot, rel)
  local abs = vim.fs.normalize(nroot .. "/" .. rel)
  marked[abs] = true
  local dir = vim.fs.dirname(abs)
  while dir and #dir >= #nroot do
    marked[dir] = true
    if dir == nroot then
      break
    end
    dir = vim.fs.dirname(dir)
  end
end

--- Rebuild M.marked (tree decorator set) from live comments and drafts.
---@param root string
function M.rebuild_marked(root)
  local marked = {}
  local nroot = vim.fs.normalize(root)
  for rel, list in pairs(M.by_path) do
    for _, c in ipairs(list) do
      if comment_visible(c) then
        mark_with_ancestors(marked, nroot, rel)
        break
      end
    end
  end
  for rel, list in pairs(M.drafts) do
    if #list > 0 then
      mark_with_ancestors(marked, nroot, rel)
    end
  end
  M.marked = marked
end

local function persist_drafts(root)
  save_drafts(root)
  M.rebuild_marked(root)
end

-- ---------------------------------------------------------------------------

--- The open PR for the branch checked out in `root`. Returns {number, head} or
--- nil (no PR, or the user dismissed the picker). Prompts once when a branch has
--- several open PRs and remembers the choice.
---@param root string
---@return { number: integer, head: string }?
local function resolve_pr(root)
  local branch = vim.trim(sh({ "git", "-C", root, "branch", "--show-current" }).stdout or "")
  if branch == "" then
    return nil
  end
  local prs = gh_json(
    { "pr", "list", "--head", branch, "--state", "open", "--json", "number,headRefOid,title" },
    root
  )
  if not prs or #prs == 0 then
    return nil
  end

  local chosen
  if #prs == 1 then
    chosen = prs[1]
  elseif M.pr_choice and M.pr_choice.branch == branch then
    for _, pr in ipairs(prs) do
      if pr.number == M.pr_choice.number then
        chosen = pr
      end
    end
    chosen = chosen or prs[1]
  else
    local labels = {}
    for _, pr in ipairs(prs) do
      labels[#labels + 1] = ("#%d  %s"):format(pr.number, pr.title)
    end
    local idx = pick(labels, { prompt = "Multiple open PRs for this branch:" })
    if not idx then
      return nil
    end
    chosen = prs[idx]
    M.pr_choice = { branch = branch, number = chosen.number }
  end
  return { number = chosen.number, head = chosen.headRefOid }
end

--- Join the branch PR's review threads (GraphQL) back onto the REST comments,
--- which carry no resolution or thread-grouping fields. Returns, keyed by REST
--- comment id (== GraphQL databaseId): `resolved` (true for comments in a resolved
--- thread, for the display filter) and `thread_of` (the thread's GraphQL node id,
--- needed to resolve/unresolve it — REST ids won't do). Fails open: any error
--- returns empty maps so a hiccup shows comments rather than hiding them, and
--- leaves resolve unavailable rather than acting on a stale id.
---@param root string
---@param number integer
---@return table<integer, boolean> resolved, table<integer, string> thread_of
local function review_threads(root, number)
  local repo = gh_json({ "repo", "view", "--json", "owner,name" }, root)
  local owner = repo and repo.owner and repo.owner.login
  local name = repo and repo.name
  if not owner or not name then
    return {}, {}
  end
  local query = [[
    query($owner:String!,$name:String!,$number:Int!){
      repository(owner:$owner,name:$name){
        pullRequest(number:$number){
          reviewThreads(first:100){
            nodes{ id isResolved comments(first:100){ nodes{ databaseId } } }
          }
        }
      }
    }
  ]]
  -- stylua: ignore
  local data = gh_json({
    "api", "graphql",
    "-f", "query=" .. query,
    "-f", "owner=" .. owner,
    "-f", "name=" .. name,
    "-F", "number=" .. number,
  }, root)
  local threads =
    vim.tbl_get(data or {}, "data", "repository", "pullRequest", "reviewThreads", "nodes")
  local resolved, thread_of = {}, {}
  for _, thread in ipairs(threads or {}) do
    for _, c in ipairs(thread.comments.nodes) do
      if c.databaseId then
        thread_of[c.databaseId] = thread.id
        if thread.isResolved then
          resolved[c.databaseId] = true
        end
      end
    end
  end
  return resolved, thread_of
end

--- The authenticated GitHub login (cached). Used to find your own comments.
---@param root string
---@return string?
local function resolve_viewer(root)
  if M.viewer then
    return M.viewer
  end
  local obj = sh({ "gh", "api", "user", "--jq", ".login" }, root)
  if obj.code == 0 then
    M.viewer = vim.trim(obj.stdout)
  end
  return M.viewer
end

--- Fill M.names for any of `logins` not yet looked up (one gh call each, but
--- only once per login per session). Runs in a coroutine like the other gh work.
---@param root string
---@param logins table<string, boolean> set of login -> true
local function resolve_names(root, logins)
  for login in pairs(logins) do
    if M.names[login] == nil then
      -- `.name // ""` yields "" (not null) when the user has no display name.
      local obj = sh({ "gh", "api", "users/" .. login, "--jq", '.name // ""' }, root)
      M.names[login] = (obj.code == 0) and vim.trim(obj.stdout) or ""
    end
  end
end

--- Header chunks for a comment author: "Display Name - @login" (the handle in a
--- quieter hue) when a display name is known, else just "@login".
---@param login string
---@return table[] virt_text chunks
local function author_chunks(login)
  local name = M.names[login]
  if name and name ~= "" then
    return {
      { name, "ReviewCommentAuthor" },
      { " - @" .. login, "ReviewComment" },
    }
  end
  return { { "@" .. login, "ReviewCommentAuthor" } }
end

--- The cached comments anchored at the current cursor line (a thread), with the
--- context needed to act on them. Returns (thread, rel, root) or nil.
---@return table[]?, string?, string?
local function thread_at_cursor()
  local root = current_root()
  if not root then
    return nil
  end
  local rel = rel_of(vim.api.nvim_get_current_buf(), root)
  if not rel then
    return nil
  end
  local line = vim.fn.line(".")
  local thread = {}
  for _, c in ipairs(M.by_path[rel] or {}) do
    -- Match the rendered anchor: an outdated comment (line nulled) shows on
    -- original_line, so act on it there too. Skip comments hidden by a toggle.
    if comment_visible(c) and (val(c.line) or val(c.original_line)) == line then
      thread[#thread + 1] = c
    end
  end
  return thread, rel, root
end

--- A scratch float to compose text. Calls on_submit(body, close) on <C-s>.
--- `initial` prefills it (and skips insert mode, e.g. when editing). By default
--- an empty body cancels (closes without submitting); `allow_empty` lets an
--- empty body through instead (the review summary is optional, so <C-s> on an
--- empty float still submits).
---@param title string
---@param initial string[]?
---@param on_submit fun(body: string, close: fun())
---@param allow_empty boolean?
local function open_input(title, initial, on_submit, allow_empty)
  local input = vim.api.nvim_create_buf(false, true)
  vim.bo[input].filetype = "markdown"
  vim.bo[input].bufhidden = "wipe"
  if initial and #initial > 0 then
    vim.api.nvim_buf_set_lines(input, 0, -1, false, initial)
  end
  local width = math.min(80, vim.o.columns - 4)
  local win = vim.api.nvim_open_win(input, true, {
    relative = "editor",
    width = width,
    height = 8,
    row = vim.o.lines - 11,
    col = math.floor((vim.o.columns - width) / 2),
    border = "rounded",
    title = (" %s  ·  <C-s> send  ·  q cancel "):format(title),
    style = "minimal",
  })
  -- Match the compose area to the normal editor background (rather than the
  -- theme's NormalFloat, which is often a different, jarring shade), and wrap
  -- for comfortable prose.
  vim.wo[win].winhighlight = "NormalFloat:Normal,FloatBorder:Comment,FloatTitle:Title"
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  local function submit()
    local body = vim.trim(table.concat(vim.api.nvim_buf_get_lines(input, 0, -1, false), "\n"))
    if body == "" and not allow_empty then
      close()
      return
    end
    on_submit(body, close)
  end
  vim.keymap.set({ "n", "i" }, "<C-s>", submit, { buffer = input, desc = "Send" })
  vim.keymap.set("n", "q", close, { buffer = input, desc = "Cancel" })
  if not (initial and #initial > 0) then
    vim.cmd("startinsert")
  end
end

-- Column width to soft-wrap inline comment bodies to. virt_lines don't wrap on
-- their own, so long lines (e.g. a bare URL) would run off the right edge.
local WRAP_WIDTH = 80

--- Soft-wrap `text` to WRAP_WIDTH columns, breaking on spaces and hard-breaking
--- any token longer than the width (e.g. a bare URL). Empty input -> {""}.
--- Counts bytes, so wide multibyte text wraps a touch early — fine for prose.
---@param text string
---@return string[]
local function wrap_text(text)
  local lines, cur = {}, ""
  for word in text:gmatch("%S+") do
    while #word > WRAP_WIDTH do -- token too long to ever fit: bite off a chunk
      if cur ~= "" then
        lines[#lines + 1], cur = cur, ""
      end
      lines[#lines + 1], word = word:sub(1, WRAP_WIDTH), word:sub(WRAP_WIDTH + 1)
    end
    local sep = cur == "" and "" or " "
    if #cur + #sep + #word > WRAP_WIDTH then
      lines[#lines + 1], cur = cur, word
    else
      cur = cur .. sep .. word
    end
  end
  lines[#lines + 1] = cur
  return lines
end

--- Group a buffer's comments and drafts by the row they render on: the
--- anchor->entries map keying render_buf's draw and comment navigation, so
--- markers and jumps agree on every position. Live comments are remapped from
--- their base commit to the working copy (see remap_line); drafts anchor on their
--- own line. Returns nil while comments are hidden or the buffer holds none.
---@param buf integer
---@return table<integer, table[]>?
local function buf_by_line(buf)
  if not M.shown or not M.root then
    return nil
  end
  local rel = rel_of(buf, M.root)
  if not rel then
    return nil
  end
  local live = M.by_path[rel]
  local drafts = M.drafts_root == M.root and M.drafts[rel] or nil
  if not live and not drafts then
    return nil
  end

  -- Group a line's comments into one stacked thread. For live comments, `line`
  -- is the position at the PR's latest commit; when GitHub marks a comment
  -- outdated it nulls `line`, so we fall back to original_line and flag the
  -- entry so it renders as outdated. Drafts anchor on their own end line. Each
  -- entry carries its kind so it renders in the right hue.
  local by_line = {}
  local function add(anchor, entry)
    if not anchor then
      return
    end
    by_line[anchor] = by_line[anchor] or {}
    table.insert(by_line[anchor], entry)
  end

  -- Change hunks between a comment's base commit and this buffer, cached per base
  -- commit (the buffer's path is fixed, so the sha is the only variable). Lets a
  -- comment track its line across local edits/commits; nil when the base blob
  -- isn't cached (commit not local), so we fall back to GitHub's anchor.
  local buf_text
  local hunks_cache = {}
  local function local_hunks(sha)
    local blob = sha and M.base_blob[sha .. ":" .. rel]
    if not blob then
      return nil
    end
    if hunks_cache[sha] == nil then
      buf_text = buf_text or table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      hunks_cache[sha] = vim.diff(blob, buf_text, { result_type = "indices" }) or false
    end
    return hunks_cache[sha] or nil
  end

  for _, c in ipairs(live or {}) do
    if comment_visible(c) then
      local line = val(c.line)
      local anchor, drifted = val(c.original_line), false
      if line ~= nil then
        local hunks = local_hunks(c.commit_id)
        if hunks then
          local row, tracked = M.remap_line(hunks, line)
          anchor, drifted = row, not tracked
        else
          anchor = line
        end
      end
      add(anchor, {
        kind = "live",
        c = c,
        outdated = line == nil,
        resolved = c.resolved == true,
        drifted = drifted,
      })
    end
  end
  for _, d in ipairs(drafts or {}) do
    add(d.line, { kind = "draft", d = d })
  end
  return by_line
end

--- Draw the cached comments and drafts for one buffer (no network). Clears
--- first, so it's safe to call on any redraw. A no-op while comments are hidden.
---@param buf integer
local function render_buf(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local by_line = buf_by_line(buf)
  if not by_line then
    return
  end

  local last = vim.api.nvim_buf_line_count(buf)
  for anchor, thread in pairs(by_line) do
    -- An outdated comment's original_line is numbered against the old file and
    -- may point past the current end, so clamp into range rather than drop it.
    local row = math.max(1, math.min(anchor, last))
    local virt = {}
    for _, entry in ipairs(thread) do
      if entry.kind == "draft" then
        table.insert(virt, {
          { "▌ ", "ReviewCommentDraftSign" },
          { "@you (draft, unsent)", "ReviewCommentDraft" },
        })
        for _, line in
          ipairs(vim.split((entry.d.body or ""):gsub("\r", ""), "\n", { plain = true }))
        do
          for _, seg in ipairs(wrap_text(line)) do
            table.insert(
              virt,
              { { "▌ ", "ReviewCommentDraftSign" }, { seg, "ReviewCommentDraft" } }
            )
          end
        end
      else
        local c = entry.c
        local header = { { "▌ ", "ReviewCommentSign" } }
        vim.list_extend(header, author_chunks(c.user.login))
        if c.side == "LEFT" then
          header[#header + 1] = { "  (removed side)", "ReviewComment" }
        end
        if entry.outdated then
          header[#header + 1] = { "  (outdated)", "ReviewCommentOutdated" }
        end
        if entry.drifted then
          header[#header + 1] = { "  (drifted)", "ReviewCommentDrifted" }
        end
        if entry.resolved then
          header[#header + 1] = { "  (resolved)", "ReviewCommentResolved" }
        end
        table.insert(virt, header)
        for _, line in ipairs(vim.split((c.body or ""):gsub("\r", ""), "\n", { plain = true })) do
          for _, seg in ipairs(wrap_text(line)) do
            table.insert(virt, { { "▌ ", "ReviewCommentSign" }, { seg, "ReviewComment" } })
          end
        end
      end
    end
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, row - 1, 0, { virt_lines = virt })
  end
end

--- Redraw every loaded buffer and the explorer from the caches (no network).
local function render_all()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      render_buf(buf)
    end
  end
  require("nitpick.adapter").redraw()
end

--- Read the file blob at `commit_id:path` for every anchored live comment whose
--- blob isn't cached yet, so render_buf can diff it against the working copy. One
--- `git show` per missing (sha, path); shas are immutable, so the cache only
--- grows. A read that fails (commit not fetched locally) is cached as false so we
--- don't retry it and the remap falls back to GitHub's line. MUST run in a
--- coroutine (uses sh).
---@param root string
local function fetch_base_blobs(root)
  local want = {}
  for _, list in pairs(M.by_path) do
    for _, c in ipairs(list) do
      local sha, path = c.commit_id, c.path
      if val(c.line) ~= nil and sha and path then
        want[sha .. ":" .. path] = true
      end
    end
  end
  for key in pairs(want) do
    if M.base_blob[key] == nil then
      local obj = sh({ "git", "-C", root, "show", key })
      M.base_blob[key] = (obj.code == 0) and obj.stdout or false
    end
  end
end

--- Fetch the branch PR's line comments and (re)draw every loaded buffer. Drafts
--- are local, so they load and render even when the branch has no PR yet.
local function fetch_render()
  run(function()
    local root = current_root()
    if not root then
      return
    end
    ensure_drafts(root)
    local pr = resolve_pr(root)
    if pr then
      -- 100 covers all but the busiest PRs; page beyond that only if it bites.
      local endpoint = ("repos/:owner/:repo/pulls/%d/comments?per_page=100"):format(pr.number)
      local comments, err = gh_json({ "api", endpoint }, root)
      if not comments then
        vim.notify("review: couldn't fetch comments: " .. tostring(err), vim.log.levels.WARN)
        M.by_path = {}
      else
        local resolved, thread_of = review_threads(root, pr.number)
        local by_path = {}
        for _, c in ipairs(comments) do
          if c.path then
            -- Keep resolved comments (tagged) so they can be toggled on rather
            -- than re-fetched; render_buf filters them per M.show_resolved.
            c.resolved = resolved[c.id] == true
            c.thread_id = thread_of[c.id] -- GraphQL node id, for resolve/unresolve
            by_path[c.path] = by_path[c.path] or {}
            table.insert(by_path[c.path], c)
          end
        end
        M.by_path = by_path
        fetch_base_blobs(root)
        if #comments >= 100 then
          vim.notify("review: showing the first 100 PR comments", vim.log.levels.WARN)
        end
      end
    else
      M.by_path = {} -- no PR for this branch: only drafts show
    end

    -- Resolve display names for every commenter (cached per session), so the
    -- inline headers read "Name - @login" rather than a bare handle.
    local logins = {}
    for _, list in pairs(M.by_path) do
      for _, c in ipairs(list) do
        if c.user and c.user.login then
          logins[c.user.login] = true
        end
      end
    end
    resolve_names(root, logins)

    M.rebuild_marked(root)
    render_all()
  end)
end

--- Whether a file or folder has PR comments or drafts (for the tree decorator).
--- False while comments are hidden.
---@param abs string?
---@return boolean
function M.has_comments(abs)
  if not M.shown or not abs then
    return false
  end
  return M.marked[vim.fs.normalize(abs)] == true
end

--- Queue a draft comment on the current file. `end_line` is the anchor line;
--- `start_line` (or nil) makes it a multi-line comment spanning start..end. The
--- draft is stored locally and sent later by M.submit — nothing hits GitHub.
---@param start_line integer?
---@param end_line integer
function M.comment(start_line, end_line)
  local root = current_root()
  if not root then
    vim.notify("review: not in a git repo", vim.log.levels.WARN)
    return
  end
  local rel = rel_of(vim.api.nvim_get_current_buf(), root)
  if not rel then
    vim.notify("review: this buffer isn't a file in the repo", vim.log.levels.WARN)
    return
  end
  ensure_drafts(root)

  local title = ("Draft comment on %s:%d"):format(vim.fs.basename(rel), end_line)
  open_input(title, nil, function(body, close)
    M.drafts[rel] = M.drafts[rel] or {}
    table.insert(M.drafts[rel], {
      line = end_line,
      side = "RIGHT",
      start_line = (start_line and start_line < end_line) and start_line or nil,
      body = body,
    })
    persist_drafts(root)
    close()
    vim.notify("review: comment drafted — submit the review with <leader>rS")
    render_all()
  end)
end

--- Discard the draft comment(s) on the cursor line (asks which if several).
function M.discard_draft()
  local root = current_root()
  if not root then
    return
  end
  ensure_drafts(root)
  local rel = rel_of(vim.api.nvim_get_current_buf(), root)
  if not rel then
    return
  end
  local line = vim.fn.line(".")
  local list = M.drafts[rel] or {}
  local hits = {}
  for i, d in ipairs(list) do
    if d.line == line then
      hits[#hits + 1] = i
    end
  end
  if #hits == 0 then
    vim.notify("review: no draft on this line", vim.log.levels.INFO)
    return
  end

  local function remove(i)
    table.remove(list, i)
    if #list == 0 then
      M.drafts[rel] = nil
    end
    persist_drafts(root)
    render_all()
    vim.notify("review: draft discarded")
  end

  if #hits == 1 then
    remove(hits[1])
    return
  end
  local labels = {}
  for _, i in ipairs(hits) do
    labels[#labels + 1] = (list[i].body:gsub("%s+", " ")):sub(1, 50)
  end
  run(function()
    local idx = pick(labels, { prompt = "Discard which draft?" })
    if idx then
      remove(hits[idx])
    end
  end)
end

--- Reply to the comment thread anchored at the cursor line. Posts immediately
--- (replies aren't batched — they're rare and not the spam source).
function M.reply()
  local thread, _, root = thread_at_cursor()
  if not thread or #thread == 0 then
    vim.notify("review: no PR comment on this line (is review mode on?)", vim.log.levels.INFO)
    return
  end
  local target = thread[1].id -- the thread root; GitHub attaches the reply to it
  open_input("Reply", nil, function(body, close)
    run(function()
      local pr = resolve_pr(root)
      if not pr then
        vim.notify("review: no open PR for this branch", vim.log.levels.INFO)
        return
      end
      local obj = sh({
        "gh",
        "api",
        "--method",
        "POST",
        ("repos/:owner/:repo/pulls/%d/comments/%d/replies"):format(pr.number, target),
        "-f",
        "body=" .. body,
      }, root)
      if obj.code == 0 then
        close()
        vim.notify("review: reply posted")
        fetch_render()
      else
        vim.notify("review: reply failed: " .. gh_error(obj), vim.log.levels.ERROR)
      end
    end)
  end)
end

--- Resolve (or unresolve) the review thread anchored at the cursor line. The
--- direction toggles on the thread's current state, and only GitHub-backed threads
--- qualify — a line carrying only unsent drafts has nothing to resolve. Uses the
--- GraphQL mutation (REST can't resolve threads) with the thread's node id, which
--- fetch stamps onto each comment as c.thread_id.
function M.resolve()
  local thread, _, root = thread_at_cursor()
  if not thread or #thread == 0 then
    vim.notify("review: no PR comment on this line (is review mode on?)", vim.log.levels.INFO)
    return
  end
  local thread_id, currently_resolved
  for _, c in ipairs(thread) do
    if c.thread_id then
      thread_id, currently_resolved = c.thread_id, c.resolved == true
      break
    end
  end
  if not thread_id then
    vim.notify(
      "review: couldn't find the thread id (try <leader>rC to refresh)",
      vim.log.levels.WARN
    )
    return
  end

  local mutation = currently_resolved and "unresolveReviewThread" or "resolveReviewThread"
  run(function()
    local query = ([[
      mutation($id:ID!){ %s(input:{threadId:$id}){ thread{ isResolved } } }
    ]]):format(mutation)
    -- stylua: ignore
    local obj = sh({
      "gh", "api", "graphql",
      "-f", "query=" .. query,
      "-f", "id=" .. thread_id,
    }, root)
    if obj.code == 0 then
      vim.notify("review: thread " .. (currently_resolved and "unresolved" or "resolved"))
      fetch_render()
    else
      vim.notify("review: resolve failed: " .. gh_error(obj), vim.log.levels.ERROR)
    end
  end)
end

--- Edit the comment on the cursor line. Draft-aware: your unsent drafts and your
--- own live comments on the line are both editable — one of each acts directly,
--- several offers a pick. A draft edit mutates local state; a live edit PATCHes.
function M.edit()
  local root = current_root()
  if not root then
    return
  end
  ensure_drafts(root)
  local rel = rel_of(vim.api.nvim_get_current_buf(), root)
  if not rel then
    return
  end
  local line = vim.fn.line(".")

  local draft_hits = {}
  for _, d in ipairs(M.drafts[rel] or {}) do
    if d.line == line then
      draft_hits[#draft_hits + 1] = d
    end
  end

  local function edit_draft(d)
    open_input(
      "Edit draft",
      vim.split(d.body:gsub("\r", ""), "\n", { plain = true }),
      function(body, close)
        d.body = body
        persist_drafts(root)
        close()
        vim.notify("review: draft updated")
        render_all()
      end
    )
  end

  local function edit_live(c)
    open_input(
      "Edit comment",
      vim.split(c.body:gsub("\r", ""), "\n", { plain = true }),
      function(body, close)
        run(function()
          local obj = sh({
            "gh",
            "api",
            "--method",
            "PATCH",
            ("repos/:owner/:repo/pulls/comments/%d"):format(c.id),
            "-f",
            "body=" .. body,
          }, root)
          if obj.code == 0 then
            close()
            vim.notify("review: comment updated")
            fetch_render()
          else
            vim.notify("review: edit failed: " .. gh_error(obj), vim.log.levels.ERROR)
          end
        end)
      end
    )
  end

  run(function()
    -- Resolving the viewer needs the network, so build the "mine" set here.
    local login = resolve_viewer(root)
    local items = {}
    for _, d in ipairs(draft_hits) do
      items[#items + 1] =
        { kind = "draft", d = d, label = "[draft] " .. (d.body:gsub("%s+", " ")):sub(1, 50) }
    end
    for _, c in ipairs(M.by_path[rel] or {}) do
      if
        comment_visible(c)
        and (val(c.line) or val(c.original_line)) == line
        and login
        and c.user.login == login
      then
        items[#items + 1] = {
          kind = "live",
          c = c,
          label = "@" .. login .. " " .. (c.body:gsub("%s+", " ")):sub(1, 50),
        }
      end
    end

    if #items == 0 then
      vim.notify("review: nothing of yours to edit on this line", vim.log.levels.INFO)
      return
    end
    local chosen = items[1]
    if #items > 1 then
      local labels = {}
      for _, it in ipairs(items) do
        labels[#labels + 1] = it.label
      end
      local idx = pick(labels, { prompt = "Edit which?" })
      if not idx then
        return
      end
      chosen = items[idx]
    end

    -- Defer: when a picker ran, this coroutine resumes inside vim.ui.select's
    -- teardown, where opening a float races the picker closing its window. A
    -- scheduled tick lets that settle first. (Harmless on the single-match path.)
    vim.schedule(function()
      if chosen.kind == "draft" then
        edit_draft(chosen.d)
      else
        edit_live(chosen.c)
      end
    end)
  end)
end

--- Submit all drafts as one GitHub review. The verdict (approve /
--- request-changes / comment) comes from the injected status source
--- (M.opts.verdict) when configured — inferred, not chosen — else a picker asks;
--- a compose float then shows it in its title and takes an optional review
--- summary — <C-s> sends (even empty), q cancels, so the float is the
--- confirmation. On success every draft is cleared, so continuing the review
--- starts a fresh batch. Submitting with no drafts sends a bare verdict (e.g. a
--- plain approve).
--- The line numbers GitHub will accept a review comment on, per repo-relative
--- path and side: `right` (head-side — added and context lines) and `left`
--- (base-side — deleted and context lines). A comment whose (path, line, side)
--- isn't one of these 422s the whole review, so submit validates against this
--- first. Parses `gh pr diff`; returns nil if that call fails, and the caller
--- then skips validation and lets GitHub arbitrate as before.
---@param root string
---@param number integer
---@return table<string, { right: table<integer, boolean>, left: table<integer, boolean> }>?
local function pr_diff_lines(root, number)
  local obj = sh({ "gh", "pr", "diff", tostring(number) }, root)
  if obj.code ~= 0 then
    return nil
  end
  -- Walk the unified diff, tracking head/base line counters per hunk header
  -- (@@ -base,_ +head,_ @@) and marking each line the API can anchor to.
  local files, cur, rline, lline = {}, nil, nil, nil
  for line in (obj.stdout .. "\n"):gmatch("(.-)\n") do
    local newpath = line:match("^%+%+%+ b/(.*)")
    if newpath then
      cur = { right = {}, left = {} }
      files[newpath] = cur
    elseif not line:match("^%-%-%- ") then -- ignore the old-path header
      local base, head = line:match("^@@ %-(%d+),?%d* %+(%d+),?%d* @@")
      if base then
        lline, rline = tonumber(base), tonumber(head)
      elseif cur and rline then
        local sign = line:sub(1, 1)
        if sign == "+" then
          cur.right[rline] = true
          rline = rline + 1
        elseif sign == "-" then
          cur.left[lline] = true
          lline = lline + 1
        elseif sign == " " then
          cur.right[rline], cur.left[lline] = true, true
          rline, lline = rline + 1, lline + 1
        end
      end
    end
  end
  return files
end

--- Fold off-diff drafts into one block for the review body: each as its
--- `path:line` location, a blank line, then the comment. So a note GitHub won't
--- anchor inline still reads as "this line, this comment". Entries divided by a
--- horizontal rule.
---@param offdiff { path: string, line: integer, body: string }[]
---@return string
local function fold_offdiff(offdiff)
  local parts = {}
  for _, o in ipairs(offdiff) do
    parts[#parts + 1] = ("%s:%d\n\n%s"):format(o.path, o.line, o.body)
  end
  return table.concat(parts, "\n\n---\n\n")
end

function M.submit()
  local root = current_root()
  if not root then
    vim.notify("review: not in a git repo", vim.log.levels.WARN)
    return
  end
  ensure_drafts(root)

  local draft_count = 0
  for _, list in pairs(M.drafts) do
    draft_count = draft_count + #list
  end
  run(function()
    -- The review event. An injected status source (opts.verdict, wired to
    -- triage.nvim here) infers it; nil there means "mid-review", i.e. COMMENT.
    -- With no source configured, ask — cancelling the picker aborts the submit.
    local verdict
    if M.opts.verdict then
      verdict = M.opts.verdict()
      if not verdict and draft_count == 0 then
        vim.notify("review: nothing to submit", vim.log.levels.INFO)
        return
      end
      verdict = verdict or "COMMENT"
    else
      local events = { "COMMENT", "APPROVE", "REQUEST_CHANGES" }
      local idx = pick(events, { prompt = "Submit review as:" })
      if not idx then
        return
      end
      verdict = events[idx]
    end

    -- Resolve the PR before composing, so a missing PR fails fast rather than
    -- after you've typed a summary.
    local pr = resolve_pr(root)
    if not pr then
      vim.notify("review: no open PR for this branch", vim.log.levels.INFO)
      return
    end

    -- Partition drafts into those GitHub will anchor inline and those off the
    -- diff. Off-diff ones can't be line comments (one would 422 the whole batch),
    -- so we fold them into the review summary instead — but that drops their
    -- inline anchor, so we confirm below and let the reviewer back out to move
    -- them first. A nil diff (fetch failed) skips validation: treat all as inline
    -- and let GitHub arbitrate, the pre-change behaviour.
    local diff_lines = pr_diff_lines(root, pr.number)
    local inline, offdiff = {}, {}
    for rel, list in pairs(M.drafts) do
      for _, d in ipairs(list) do
        local side = d.side or "RIGHT"
        local set = diff_lines
          and diff_lines[rel]
          and (side == "LEFT" and diff_lines[rel].left or diff_lines[rel].right)
        local ok = diff_lines == nil
          or (set ~= nil and set[d.line] and (not d.start_line or set[d.start_line]))
        if ok then
          local c = { path = rel, line = d.line, side = side, body = d.body }
          if d.start_line then
            c.start_line = d.start_line
            c.start_side = side
          end
          inline[#inline + 1] = c
        else
          offdiff[#offdiff + 1] = { path = rel, line = d.line, body = d.body }
        end
      end
    end

    -- Warn before turning inline comments into summary text: it's a real change
    -- in where they land, so name them and let the reviewer cancel to move them.
    if #offdiff > 0 then
      local names = {}
      for _, o in ipairs(offdiff) do
        names[#names + 1] = ("%s:%d"):format(o.path, o.line)
      end
      local idx = pick({ "Fold into summary and submit", "Cancel (move them first)" }, {
        prompt = ("%d comment(s) aren't on the diff — they'll be folded into the review summary and lose their inline anchor: %s"):format(
          #offdiff,
          table.concat(names, ", ")
        ),
      })
      if idx ~= 1 then
        return
      end
    end

    local title = ("Submit as %s · %d inline + %d folded · summary optional"):format(
      verdict,
      #inline,
      #offdiff
    )
    open_input(title, nil, function(body, close)
      run(function()
        local payload = { commit_id = pr.head, event = verdict }
        if #inline > 0 then
          payload.comments = inline
        end
        -- Body = typed summary, then the folded off-diff block, each present only
        -- if non-empty.
        local sections = {}
        if body ~= "" then
          sections[#sections + 1] = body
        end
        if #offdiff > 0 then
          sections[#sections + 1] = fold_offdiff(offdiff)
        end
        if #sections > 0 then
          payload.body = table.concat(sections, "\n\n")
        elseif verdict == "APPROVE" then
          payload.body = "LGTM" -- a bare approval shouldn't go out wordless
        end
        local obj = sh({
          "gh",
          "api",
          "--method",
          "POST",
          ("repos/:owner/:repo/pulls/%d/reviews"):format(pr.number),
          "--input",
          "-",
        }, root, vim.json.encode(payload))

        if obj.code == 0 then
          -- Success means every draft landed (inline or folded) — clear them all.
          close()
          M.drafts = {}
          save_drafts(root)
          vim.notify(
            ("review: submitted %s (%d inline, %d folded)"):format(verdict, #inline, #offdiff)
          )
          fetch_render()
        else
          -- Keep the float open so the typed summary isn't lost on a failure.
          vim.notify("review: submit failed: " .. gh_error(obj), vim.log.levels.ERROR)
        end
      end)
    end, true) -- allow an empty summary to submit
  end)
end

--- Show or hide inline comments. Showing fetches from GitHub; hiding just clears.
---@param on boolean
function M.set_shown(on)
  M.shown = on
  if on then
    fetch_render()
  else
    M.marked = {}
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) then
        vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
      end
    end
    require("nitpick.adapter").redraw()
  end
end

--- Re-fetch from GitHub and redraw (manual refresh).
function M.refresh()
  if M.shown then
    fetch_render()
  end
end

--- Re-mark and redraw from the caches after a visibility toggle (no network).
local function redisplay()
  if M.root then
    M.rebuild_marked(M.root)
  end
  render_all()
end

--- Toggle whether outdated comments (anchor line gone) are drawn.
function M.toggle_outdated()
  M.show_outdated = not M.show_outdated
  vim.notify("review: outdated comments " .. (M.show_outdated and "shown" or "hidden"))
  redisplay()
end

--- Toggle whether comments in resolved threads are drawn.
function M.toggle_resolved()
  M.show_resolved = not M.show_resolved
  vim.notify("review: resolved comments " .. (M.show_resolved and "shown" or "hidden"))
  redisplay()
end

--- The extra comment categories currently shown beyond current/unresolved, for
--- the review-mode status string. "" when only the default set is visible.
---@return string
function M.display_summary()
  local extra = {}
  if M.show_outdated then
    extra[#extra + 1] = "outdated"
  end
  if M.show_resolved then
    extra[#extra + 1] = "resolved"
  end
  return table.concat(extra, "+")
end

--- The comment fragment for the statusline: a speech bubble once comments are
--- shown, plus a trailing "+outdated"/"+resolved" naming any category on beyond
--- the default (current, unresolved) set, so the toggles are discoverable. Empty
--- while comments are hidden, so the statusline component collapses to nothing.
--- (triage.nvim contributes the base separately; lualine concatenates the two.)
---@return string
function M.statusline()
  if not M.shown then
    return ""
  end
  local bubble = "\xef\x81\xb5" -- U+F075 nerd-font speech bubble (fa-comment)
  local extra = M.display_summary()
  return bubble .. (extra ~= "" and (" +" .. extra:gsub("%+", " +")) or "")
end

--- The nearest row strictly past `cur` in direction `dir` (1 forward, -1 back)
--- from ascending `rows`. Strict, so a jump always leaves the current line; no
--- wrap, so nil means "nothing further that way".
---@param rows integer[] ascending
---@param cur integer
---@param dir integer
---@return integer?
function M.next_anchor(rows, cur, dir)
  if dir > 0 then
    for _, r in ipairs(rows) do
      if r > cur then
        return r
      end
    end
  else
    for i = #rows, 1, -1 do
      if rows[i] < cur then
        return rows[i]
      end
    end
  end
  return nil
end

--- Move the cursor to the next (dir=1) or previous (dir=-1) comment/draft anchor
--- in the current buffer, using the same rows render_buf draws on so a jump always
--- lands on a visible marker. Sets the ' mark first (so '' / <C-o> return), clamps
--- into the buffer, and centers; notifies when there's nothing further that way.
---@param dir integer
function M.jump_comment(dir)
  local buf = vim.api.nvim_get_current_buf()
  local by_line = buf_by_line(buf)
  if not by_line then
    vim.notify("review: no PR comments in this file (is review mode on?)", vim.log.levels.INFO)
    return
  end
  local last = vim.api.nvim_buf_line_count(buf)
  local rows = {}
  for anchor in pairs(by_line) do
    rows[#rows + 1] = math.max(1, math.min(anchor, last))
  end
  table.sort(rows)

  local target = M.next_anchor(rows, vim.fn.line("."), dir)
  if not target then
    vim.notify(
      "review: no " .. (dir > 0 and "further" or "earlier") .. " comment in this file",
      vim.log.levels.INFO
    )
    return
  end
  vim.cmd("normal! m'") -- leave a jump-back point before moving
  vim.api.nvim_win_set_cursor(0, { target, 0 })
  vim.cmd("normal! zz")
end

-- Default keymaps, action -> left-hand side. Override or disable individually
-- via opts.keys (set an action to false/"" to leave it unmapped). `comment` maps
-- in both normal (line) and visual (range) mode on the one key.
local default_keys = {
  comment = "<leader>rc",
  reply = "<leader>ra",
  resolve = "<leader>rk",
  next = "]r",
  prev = "[r",
  edit = "<leader>re",
  discard = "<leader>rx",
  submit = "<leader>rS",
  refresh = "<leader>rC",
  outdated = "<leader>ro",
  resolved = "<leader>rs",
}

--- Configure nitpick.nvim.
---@param opts? { verdict?: fun(): ("APPROVE"|"REQUEST_CHANGES"|"COMMENT"|nil), keys?: table<string, string|false> }
---   verdict  status source for submit's review event; nil prompts via a picker.
---            Wire it to triage.nvim's verdict to infer the event from triage.
---   keys     per-action left-hand side; see default_keys. false/"" disables one.
function M.setup(opts)
  M.opts = opts or {}
  local function set_hl()
    vim.api.nvim_set_hl(0, "ReviewComment", { link = "Comment", default = true })
    vim.api.nvim_set_hl(0, "ReviewCommentAuthor", { link = "Title", default = true })
    vim.api.nvim_set_hl(0, "ReviewCommentSign", { link = "DiagnosticInfo", default = true })
    -- Drafts (unsent) read in a quieter hue than live comments, so what's
    -- already on GitHub and what you've only queued are visually distinct.
    vim.api.nvim_set_hl(0, "ReviewCommentDraft", { link = "DiagnosticHint", default = true })
    vim.api.nvim_set_hl(0, "ReviewCommentDraftSign", { link = "DiagnosticHint", default = true })
    -- Header tags for comments GitHub no longer anchors (outdated) or that live
    -- in a resolved thread: outdated warns (stale anchor), resolved reads dim.
    vim.api.nvim_set_hl(0, "ReviewCommentOutdated", { link = "DiagnosticWarn", default = true })
    vim.api.nvim_set_hl(0, "ReviewCommentResolved", { link = "Comment", default = true })
    -- Drifted: the commented line was edited/removed in the working copy, so the
    -- anchor is only approximate. Warns, like outdated, but is a distinct group.
    vim.api.nvim_set_hl(0, "ReviewCommentDrifted", { link = "DiagnosticWarn", default = true })
    -- The tree's comment marker: plain foreground (whiteish in dark themes) so it
    -- reads as a neutral "has comments" flag, not a coloured status glyph.
    vim.api.nvim_set_hl(0, "ReviewCommentTreeIcon", { link = "Normal", default = true })
  end
  vim.api.nvim_create_autocmd("ColorScheme", { callback = set_hl })
  set_hl()

  -- Draw cached comments on buffers as they load/show (cheap; no network).
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWinEnter" }, {
    callback = function(a)
      if M.shown then
        render_buf(a.buf)
      end
    end,
  })

  -- Re-anchor after edits: the working-copy remap diffs the base blob against the
  -- live buffer, so a comment only follows its line once we redraw. TextChanged
  -- (one event per normal-mode change) and InsertLeave keep it current without
  -- diffing on every keystroke; render_buf no-ops on buffers without comments.
  vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
    callback = function(a)
      if M.shown then
        render_buf(a.buf)
      end
    end,
  })

  local keys = vim.tbl_extend("force", default_keys, M.opts.keys or {})
  local function mapk(action, mode, rhs, desc)
    local lhs = keys[action]
    if lhs and lhs ~= "" then
      vim.keymap.set(mode, lhs, rhs, { desc = desc })
    end
  end
  -- `comment` binds in both normal (line under cursor) and visual (range) mode.
  mapk("comment", "n", function()
    M.comment(nil, vim.fn.line("."))
  end, "Review: draft comment on line (PR)")
  mapk("comment", "x", function()
    local a, b = vim.fn.line("v"), vim.fn.line(".")
    if a > b then
      a, b = b, a
    end
    M.comment(a == b and nil or a, b)
  end, "Review: draft comment on range (PR)")
  mapk("reply", "n", M.reply, "Review: reply to PR comment on line")
  mapk("resolve", "n", M.resolve, "Review: resolve/unresolve PR thread on line")
  mapk("next", "n", function()
    M.jump_comment(1)
  end, "Review: jump to next PR comment")
  mapk("prev", "n", function()
    M.jump_comment(-1)
  end, "Review: jump to previous PR comment")
  mapk("edit", "n", M.edit, "Review: edit PR comment/draft on line")
  mapk("discard", "n", M.discard_draft, "Review: discard draft on line")
  mapk("submit", "n", M.submit, "Review: submit drafted review (batched)")
  mapk("refresh", "n", M.refresh, "Review: refresh PR comments")
  mapk("outdated", "n", M.toggle_outdated, "Review: toggle outdated comments")
  mapk("resolved", "n", M.toggle_resolved, "Review: toggle resolved comments")

  vim.api.nvim_create_user_command("ReviewComment", function()
    M.comment(nil, vim.fn.line("."))
  end, { desc = "Draft a comment on the current line for the branch PR" })
  vim.api.nvim_create_user_command(
    "ReviewReply",
    M.reply,
    { desc = "Reply to the PR comment on this line" }
  )
  vim.api.nvim_create_user_command(
    "ReviewResolve",
    M.resolve,
    { desc = "Resolve/unresolve the PR thread on this line" }
  )
  vim.api.nvim_create_user_command("ReviewNextComment", function()
    M.jump_comment(1)
  end, { desc = "Jump to the next PR comment in this file" })
  vim.api.nvim_create_user_command("ReviewPrevComment", function()
    M.jump_comment(-1)
  end, { desc = "Jump to the previous PR comment in this file" })
  vim.api.nvim_create_user_command(
    "ReviewEditComment",
    M.edit,
    { desc = "Edit your PR comment/draft on this line" }
  )
  vim.api.nvim_create_user_command(
    "ReviewDiscardDraft",
    M.discard_draft,
    { desc = "Discard the draft on this line" }
  )
  vim.api.nvim_create_user_command(
    "ReviewSubmit",
    M.submit,
    { desc = "Submit the drafted review to the PR" }
  )
  vim.api.nvim_create_user_command(
    "ReviewCommentsRefresh",
    M.refresh,
    { desc = "Re-fetch PR comments" }
  )
  vim.api.nvim_create_user_command(
    "ReviewToggleOutdated",
    M.toggle_outdated,
    { desc = "Toggle display of outdated PR comments" }
  )
  vim.api.nvim_create_user_command(
    "ReviewToggleResolved",
    M.toggle_resolved,
    { desc = "Toggle display of resolved PR comments" }
  )
end

return M
