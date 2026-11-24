-- A PR as an editable buffer (nitpick://pr/<owner>/<name>/<number>): the
-- stack it is in as its title block, the PR's own row holding its editable
-- title, then a header of its state, author, merge state and checks, then its
-- editable description. :w (or <C-s>) saves the title and description to GitHub.

local async = require("nitpick.async")
local branch_pr = require("nitpick.branch_pr")
local checkout = require("nitpick.checkout")

local M = {}

---@class nitpick.PrClient
---@field fetch fun(ref: nitpick.PrRef): nitpick.Pr?, string?
---@field update fun(id: string, fields: { title: string?, body: string? }): boolean, string?
---@field stack fun(ref: nitpick.PrRef, current: nitpick.StackPr): nitpick.Stack?

---@class nitpick.PrBufferState
---@field ref nitpick.PrRef
---@field client nitpick.PrClient
---@field pr nitpick.Pr? as last loaded, what edits are measured against
---@field check_urls table<integer, string> check row's extmark id -> its URL
---@field stack_rows table<integer, nitpick.StackPr> stack row's extmark id -> its PR

---@type table<integer, nitpick.PrBufferState>
local states = {}

-- What a stack row's <CR> does with another PR in the stack; setup's on_stack_select replaces it.
---@type fun(ref: nitpick.PrRef, row: nitpick.StackPr)
local select_stack_pr = function(ref)
  vim.cmd.edit(vim.fn.fnameescape(M.uri(ref)))
end

local ns = vim.api.nvim_create_namespace("nitpick_pr")
-- Marks with no highlight that follow edits: the rows bounding the title and
-- the body, and the check and stack rows.
local ns_regions = vim.api.nvim_create_namespace("nitpick_pr_regions")
local ns_checks = vim.api.nvim_create_namespace("nitpick_pr_checks")
local ns_stack = vim.api.nvim_create_namespace("nitpick_pr_stack")

local URI_PREFIX = "nitpick://pr/"
local HEADER_END, ABOVE_TITLE, BELOW_TITLE = 1, 2, 3

--- The GitHub client PR buffers use outside the specs.
---@return nitpick.PrClient
function M.github_client()
  local pr = require("nitpick.pr")
  return { fetch = pr.fetch, update = pr.update, stack = require("nitpick.stack").fetch }
end

--- Open PR `number`, or the current branch's, in the current window.
---@param number integer?
function M.open(number)
  async.run(function()
    local root = checkout.current_root() or checkout.cwd_root()
    if not root then
      vim.notify("nitpick: not in a git repo", vim.log.levels.WARN)
      return
    end
    if not number then
      local pr = branch_pr.resolve(root)
      if not pr then
        vim.notify("nitpick: no open PR for this branch", vim.log.levels.INFO)
        return
      end
      number = pr.number
    end
    local ref, err = require("nitpick.pr").ref_for(root, number)
    if not ref then
      vim.notify("nitpick: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    vim.cmd.edit(vim.fn.fnameescape(M.uri(ref)))
  end)
end

--- The buffer showing `ref`, made unlisted and loaded on first ask, for a caller placing it in a window of its own.
---@param ref nitpick.PrRef
---@return integer buf, boolean fresh made just now, so already loading
function M.buffer(ref)
  local name = M.uri(ref)
  for buf, _ in pairs(states) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) == name then
      return buf, false
    end
  end
  local buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(buf, name)
  M.attach(buf, ref, M.github_client())
  return buf, true
end

--- Reload `buf`'s PR from GitHub, unless it holds edits not yet saved.
---@param buf integer
function M.refresh(buf)
  if states[buf] and not vim.bo[buf].modified then
    M.load(buf)
  end
end

--- Make `buf` the PR buffer of `ref`, loaded from and saved through `client`.
---@param buf integer
---@param ref nitpick.PrRef
---@param client nitpick.PrClient
function M.attach(buf, ref, client)
  states[buf] = { ref = ref, client = client, check_urls = {}, stack_rows = {} }
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      M.save(buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function()
      states[buf] = nil
    end,
  })
  vim.keymap.set({ "n", "i" }, "<C-s>", function()
    M.save(buf)
  end, { buffer = buf, desc = "Save the PR's title and description to GitHub" })
  -- Off a check row it is the builtin gd.
  vim.keymap.set("n", "gd", function()
    local url = M.check_url(buf, vim.fn.line("."))
    if url then
      vim.ui.open(url)
    else
      vim.cmd("normal! gd")
    end
  end, { buffer = buf, desc = "Open the check under the cursor" })
  -- Off a stack row it is <CR>, and gx the global gx.
  vim.keymap.set("n", "<CR>", function()
    local row = M.stack_pr(buf, vim.fn.line("."))
    if row and row.number ~= ref.number then
      select_stack_pr(vim.tbl_extend("force", ref, { number = row.number }), row)
    else
      vim.cmd("normal! \r")
    end
  end, { buffer = buf, desc = "Go to the stack's PR under the cursor" })
  local gx = vim.fn.maparg("gx", "n", false, true)
  vim.keymap.set("n", "gx", function()
    local row = M.stack_pr(buf, vim.fn.line("."))
    local pr = states[buf].pr
    if row and pr then
      vim.ui.open((pr.url:gsub("/pull/%d+$", "/pull/" .. row.number)))
    elseif gx.callback then
      gx.callback()
    end
  end, { buffer = buf, desc = "Open the stack's PR under the cursor in the browser" })
  M.load(buf)
end

--- Fetch `buf`'s PR and draw it at once as a stack of one, then again with the
--- stack once found, unless edits have begun.
---@param buf integer
function M.load(buf)
  local state = states[buf]
  async.run(function()
    local pr, err = state.client.fetch(state.ref)
    if not pr then
      vim.notify("nitpick: couldn't load the PR: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local stack = require("nitpick.stack")
    local own = stack.row_of(pr)
    M.render(buf, pr, assert(stack.order({ own }, own.number)), os.time())
    local found = state.client.stack(state.ref, own)
    if found and vim.api.nvim_buf_is_valid(buf) and not vim.bo[buf].modified then
      M.render(buf, pr, found, os.time())
    end
  end)
end

--- Save `buf`'s title and description edits to GitHub, refusing when GitHub's
--- copy of an edited field changed since the buffer loaded.
---@param buf integer
function M.save(buf)
  local state = states[buf]
  if not state.pr then
    return
  end
  local edits = M.edits(buf)
  local fields = {}
  if edits.title ~= state.pr.title then
    fields.title = edits.title
  end
  if edits.body ~= state.pr.body then
    fields.body = edits.body
  end
  if not next(fields) then
    vim.bo[buf].modified = false
    return
  end
  if fields.title == "" then
    vim.notify("nitpick: a PR needs a title", vim.log.levels.WARN)
    return
  end
  async.run(function()
    local fresh, err = state.client.fetch(state.ref)
    if not fresh then
      vim.notify("nitpick: couldn't check the PR before saving: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    local changed = M.changed_upstream(state.pr, fresh, fields)
    if #changed > 0 then
      vim.notify(
        ("nitpick: not saved, the PR's %s changed on GitHub since it loaded. Copy your edits, then :e! to reload"):format(
          table.concat(changed, " and ")
        ),
        vim.log.levels.WARN
      )
      return
    end
    local ok, update_err = state.client.update(fresh.id, fields)
    if not ok then
      vim.notify("nitpick: save failed: " .. tostring(update_err), vim.log.levels.ERROR)
      return
    end
    vim.notify("nitpick: PR saved")
    M.load(buf)
  end)
end

--- The fields among `fields` whose GitHub copy differs between `loaded` and `fresh`.
---@param loaded nitpick.Pr
---@param fresh nitpick.Pr
---@param fields { title: string?, body: string? }
---@return string[]
function M.changed_upstream(loaded, fresh, fields)
  local changed = {}
  for _, field in ipairs({ "title", "body" }) do
    if fields[field] and loaded[field] ~= fresh[field] then
      changed[#changed + 1] = field == "body" and "description" or field
    end
  end
  return changed
end

--- Replace `buf`'s text with `pr` in `stack`, as of `now` (epoch seconds).
---@param buf integer
---@param pr nitpick.Pr
---@param stack nitpick.Stack
---@param now integer
function M.render(buf, pr, stack, now)
  local layout = M.layout(pr, stack, now)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, layout.lines)
  for _, space in ipairs({ ns, ns_regions, ns_checks, ns_stack }) do
    vim.api.nvim_buf_clear_namespace(buf, space, 0, -1)
  end
  for _, h in ipairs(layout.highlights) do
    vim.api.nvim_buf_set_extmark(buf, ns, h[1] - 1, h[2], { end_col = h[3], hl_group = h[4] })
  end
  for _, d in ipairs(layout.decorations) do
    vim.api.nvim_buf_set_extmark(buf, ns, d[1] - 1, 0, d[2])
  end
  -- Marks sit on rows nobody edits, never the title's or the body's first line:
  -- replacing a line moves its marks to the next one.
  if layout.title_row > 1 then
    vim.api.nvim_buf_set_extmark(buf, ns_regions, layout.title_row - 2, 0, { id = ABOVE_TITLE })
  end
  vim.api.nvim_buf_set_extmark(buf, ns_regions, layout.title_row, 0, { id = BELOW_TITLE })
  vim.api.nvim_buf_set_extmark(buf, ns_regions, layout.body_row - 2, 0, {
    id = HEADER_END,
    virt_lines = { { { "" } }, { { ("─"):rep(60), "NitpickPrRule" } }, { { "" } } },
  })
  local check_urls, stack_rows = {}, {}
  for row, url in pairs(layout.check_urls) do
    check_urls[vim.api.nvim_buf_set_extmark(buf, ns_checks, row - 1, 0, {})] = url
  end
  for row, p in pairs(layout.stack_rows) do
    stack_rows[vim.api.nvim_buf_set_extmark(buf, ns_stack, row - 1, 0, {})] = p
  end
  states[buf].pr = pr
  states[buf].check_urls = check_urls
  states[buf].stack_rows = stack_rows
  vim.bo[buf].modified = false
end

--- The title and description as `buf` holds them now: every line between the
--- stack rows around the PR's own, and every line after the header.
---@param buf integer
---@return { title: string, body: string }
function M.edits(buf)
  local function mark_row(id)
    return vim.api.nvim_buf_get_extmark_by_id(buf, ns_regions, id, {})[1]
  end
  local above = mark_row(ABOVE_TITLE)
  local title_lines = vim.api.nvim_buf_get_lines(buf, above and above + 1 or 0, mark_row(BELOW_TITLE), false)
  return {
    title = vim.trim(table.concat(title_lines, " ")),
    body = table.concat(vim.api.nvim_buf_get_lines(buf, mark_row(HEADER_END) + 1, -1, false), "\n"),
  }
end

--- The entry `marks` holds for the mark on 1-based `row` of `buf` in namespace `space`.
---@generic T
---@param buf integer
---@param space integer
---@param marks table<integer, T>
---@param row integer
---@return T?
local function on_row(buf, space, marks, row)
  local mark = vim.api.nvim_buf_get_extmarks(buf, space, { row - 1, 0 }, { row - 1, -1 }, {})[1]
  return mark and marks[mark[1]]
end

--- The URL of the check drawn on 1-based `row` of `buf`, if one is.
---@param buf integer
---@param row integer
---@return string?
function M.check_url(buf, row)
  return states[buf] and on_row(buf, ns_checks, states[buf].check_urls, row)
end

--- The stack's PR drawn on 1-based `row` of `buf`, if one is.
---@param buf integer
---@param row integer
---@return nitpick.StackPr?
function M.stack_pr(buf, row)
  return states[buf] and on_row(buf, ns_stack, states[buf].stack_rows, row)
end

--- `ref`'s buffer name.
---@param ref nitpick.PrRef
---@return string
function M.uri(ref)
  return ("%s%s/%s/%d"):format(URI_PREFIX, ref.owner, ref.name, ref.number)
end

--- The PR a buffer name names, if it is a PR buffer's.
---@param name string
---@return nitpick.PrRef?
function M.parse_uri(name)
  local owner, repo, number = name:match("^" .. vim.pesc(URI_PREFIX) .. "([^/]+)/([^/]+)/(%d+)$")
  return owner and { owner = owner, name = repo, number = tonumber(number) } or nil
end

---@class nitpick.PrLayout
---@field lines string[]
---@field highlights { [1]: integer, [2]: integer, [3]: integer, [4]: string }[] row (1-based), start and end byte, group
---@field decorations { [1]: integer, [2]: vim.api.keyset.set_extmark }[] row (1-based) and the virtual text drawn there
---@field title_row integer
---@field body_row integer
---@field check_urls table<integer, string> row -> the check drawn there
---@field stack_rows table<integer, nitpick.StackPr> row -> the stack's PR drawn there

local STATE_TEXT = {
  open = { "Open", "NitpickPrOpen" },
  draft = { "Draft", "NitpickPrDraft" },
  merged = { "Merged", "NitpickPrMerged" },
  closed = { "Closed", "NitpickPrClosed" },
}

local MERGE_TEXT = {
  clean = { "Clean", "DiagnosticOk" },
  conflicts = { "Conflicts", "DiagnosticError" },
  blocked = { "Blocked", "DiagnosticWarn" },
  behind = { "Behind its base", "DiagnosticWarn" },
  unstable = { "Unstable", "DiagnosticWarn" },
  draft = { "Draft", "Comment" },
  unknown = { "Checking", "Comment" },
}

local REVIEW_TEXT = {
  approved = { "approved", "DiagnosticOk" },
  changes_requested = { "changes requested", "DiagnosticError" },
  review_required = { "review required", "DiagnosticWarn" },
}

-- Glyph and highlight per check state, in the order the summary counts them.
local CHECK_STATES = {
  { "failed", "\u{2717}", "DiagnosticError" },
  { "running", "\u{25cf}", "DiagnosticWarn" },
  { "skipped", "\u{2298}", "Comment" },
  { "passed", "\u{2713}", "DiagnosticOk" },
}
local CHECK_GLYPHS = {}
for _, s in ipairs(CHECK_STATES) do
  CHECK_GLYPHS[s[1]] = { s[2], s[3] }
end

-- Checks listed one per row: those needing attention. The rest are only counted.
local LISTED = { failed = true, running = true }

--- `pr` in `stack` laid out as the buffer shows it, as of `now`.
---@param pr nitpick.Pr
---@param stack nitpick.Stack
---@param now integer epoch seconds
---@return nitpick.PrLayout
function M.layout(pr, stack, now)
  local lines, highlights, decorations, check_urls, stack_rows = {}, {}, {}, {}, {}
  local function row(chunks)
    local text = ""
    for _, chunk in ipairs(chunks) do
      if chunk[2] then
        highlights[#highlights + 1] = { #lines + 1, #text, #text + #chunk[1], chunk[2] }
      end
      text = text .. chunk[1]
    end
    lines[#lines + 1] = text
  end
  local function label(text)
    return { text .. ": ", "NitpickPrLabel" }
  end

  local number_width = 0
  for _, p in ipairs(stack.rows) do
    number_width = math.max(number_width, #tostring(p.number))
  end
  local title_row
  for i, p in ipairs(stack.rows) do
    local current = i == stack.current
    row({ { current and pr.title or p.title, current and "NitpickPrTitle" or nil } })
    stack_rows[#lines] = p
    if current then
      title_row = #lines
    end
    local status = p.draft and { "draft", "Comment" } or REVIEW_TEXT[p.review] or { "" }
    local glyph = CHECK_GLYPHS[p.checks] or { " " }
    decorations[#decorations + 1] = {
      #lines,
      {
        virt_text = {
          { current and "\u{25c9} " or "\u{25cb} ", current and "NitpickPrCurrent" or "Comment" },
          { ("#%-" .. number_width .. "d  "):format(p.number), "NitpickPrNumber" },
        },
        virt_text_pos = "inline",
      },
    }
    decorations[#decorations + 1] = {
      #lines,
      { virt_text = { { status[1] .. "  ", status[2] }, { glyph[1], glyph[2] } }, virt_text_pos = "right_align" },
    }
  end
  row({ { "\u{2570} " .. stack.trunk, "Comment" } })
  row({})

  local state = STATE_TEXT[pr.state]
  row({ label("Status"), { state[1], state[2] }, { "  " .. pr.base .. " \u{2190} " .. pr.head, "NitpickPrBranch" } })
  row({
    label("Author"),
    { "@" .. pr.author.login .. (pr.author.is_bot and " (bot)" or ""), "NitpickPrAuthor" },
    { ("  opened %s \u{b7} updated %s"):format(M.ago(now - pr.created_at), M.ago(now - pr.updated_at)), "Comment" },
  })
  if pr.merge then
    local merge = MERGE_TEXT[pr.merge]
    row({ label("Merge"), { merge[1], merge[2] } })
  end

  local by_state = {}
  for _, c in ipairs(pr.checks) do
    by_state[c.state] = by_state[c.state] or {}
    table.insert(by_state[c.state], c)
  end
  local summary = { label("Checks") }
  for _, s in ipairs(CHECK_STATES) do
    local n = by_state[s[1]] and #by_state[s[1]] or 0
    if n > 0 then
      summary[#summary + 1] = { (#summary > 1 and " \u{b7} " or "") .. ("%d %s"):format(n, s[1]), s[3] }
    end
  end
  if #summary == 1 then
    summary[2] = { "none", "Comment" }
  end
  row(summary)
  for _, s in ipairs(CHECK_STATES) do
    if LISTED[s[1]] then
      for _, c in ipairs(by_state[s[1]] or {}) do
        row({ { "  " .. s[2] .. " ", s[3] }, { c.name } })
        check_urls[#lines] = c.url
      end
    end
  end

  local body_row = #lines + 1
  vim.list_extend(lines, vim.split(pr.body, "\n", { plain = true }))
  return {
    lines = lines,
    highlights = highlights,
    decorations = decorations,
    title_row = title_row,
    body_row = body_row,
    check_urls = check_urls,
    stack_rows = stack_rows,
  }
end

-- Spans for M.ago, largest first: seconds in one, and its name.
local SPANS = {
  { 365 * 86400, "year" },
  { 30 * 86400, "month" },
  { 7 * 86400, "week" },
  { 86400, "day" },
  { 3600, "hour" },
  { 60, "minute" },
}

--- `seconds` ago, as a person says it: "3 hours ago", "just now".
---@param seconds integer
---@return string
function M.ago(seconds)
  for _, span in ipairs(SPANS) do
    local n = math.floor(seconds / span[1])
    if n >= 1 then
      return ("%d %s%s ago"):format(n, span[2], n == 1 and "" or "s")
    end
  end
  return "just now"
end

--- Register the PR buffers' name scheme, :NitpickPr and their highlights.
---@param opts { on_stack_select: fun(ref: nitpick.PrRef, row: nitpick.StackPr)? }
function M.setup(opts)
  if opts.on_stack_select then
    select_stack_pr = opts.on_stack_select
  end
  local function set_hl()
    for group, link in pairs({
      NitpickPrLabel = "Comment",
      NitpickPrTitle = "Title",
      NitpickPrCurrent = "Special",
      NitpickPrNumber = "Special",
      NitpickPrOpen = "DiagnosticOk",
      NitpickPrDraft = "Comment",
      NitpickPrMerged = "Special",
      NitpickPrClosed = "DiagnosticError",
      NitpickPrBranch = "Identifier",
      NitpickPrAuthor = "Title",
      NitpickPrRule = "Comment",
    }) do
      vim.api.nvim_set_hl(0, group, { link = link, default = true })
    end
  end
  vim.api.nvim_create_autocmd("ColorScheme", { callback = set_hl })
  set_hl()

  vim.api.nvim_create_autocmd("BufReadCmd", {
    pattern = URI_PREFIX .. "*",
    callback = function(ev)
      local ref = M.parse_uri(ev.match)
      if ref then
        M.attach(ev.buf, ref, M.github_client())
      end
    end,
  })
  vim.api.nvim_create_user_command("NitpickPr", function(cmd)
    M.open(tonumber(cmd.args))
  end, { nargs = "?", desc = "Open a PR (default: the current branch's) as an editable buffer" })
end

return M
