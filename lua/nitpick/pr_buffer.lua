-- A PR as an editable buffer (nitpick://pr/<owner>/<name>/<number>): its title
-- and description are edited in place and :w (or <C-s>) saves them to GitHub,
-- under a header of its state, author, merge state and checks.

local async = require("nitpick.async")
local branch_pr = require("nitpick.branch_pr")
local checkout = require("nitpick.checkout")

local M = {}

---@class nitpick.PrClient
---@field fetch fun(ref: nitpick.PrRef): nitpick.Pr?, string?
---@field update fun(id: string, fields: { title: string?, body: string? }): boolean, string?

---@class nitpick.PrBufferState
---@field ref nitpick.PrRef
---@field client nitpick.PrClient
---@field pr nitpick.Pr? as last loaded, what edits are measured against
---@field check_urls table<integer, string> check row's extmark id -> its URL

---@type table<integer, nitpick.PrBufferState>
local states = {}

local ns = vim.api.nvim_create_namespace("nitpick_pr")
-- Marks with no highlight that follow edits: the header's last row, after which the body starts, and the check rows.
local ns_regions = vim.api.nvim_create_namespace("nitpick_pr_regions")
local ns_checks = vim.api.nvim_create_namespace("nitpick_pr_checks")

local URI_PREFIX = "nitpick://pr/"
local HEADER_END = 1

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

--- Make `buf` the PR buffer of `ref`, loaded from and saved through `client`.
---@param buf integer
---@param ref nitpick.PrRef
---@param client nitpick.PrClient
function M.attach(buf, ref, client)
  states[buf] = { ref = ref, client = client, check_urls = {} }
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
  M.load(buf)
end

--- Fetch `buf`'s PR and draw it.
---@param buf integer
function M.load(buf)
  local state = states[buf]
  async.run(function()
    local pr, err = state.client.fetch(state.ref)
    if not pr then
      vim.notify("nitpick: couldn't load the PR: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    if vim.api.nvim_buf_is_valid(buf) then
      M.render(buf, pr, os.time())
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

--- Replace `buf`'s text with `pr`, as of `now` (epoch seconds).
---@param buf integer
---@param pr nitpick.Pr
---@param now integer
function M.render(buf, pr, now)
  local layout = M.layout(pr, now)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, layout.lines)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, ns_regions, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, ns_checks, 0, -1)
  for _, h in ipairs(layout.highlights) do
    vim.api.nvim_buf_set_extmark(buf, ns, h[1] - 1, h[2], { end_col = h[3], hl_group = h[4] })
  end
  -- On the header, never the body's first line: replacing a line moves its marks to the next one.
  vim.api.nvim_buf_set_extmark(buf, ns_regions, layout.body_row - 2, 0, {
    id = HEADER_END,
    virt_lines = { { { "" } }, { { ("─"):rep(60), "NitpickPrRule" } }, { { "" } } },
  })
  local check_urls = {}
  for row, url in pairs(layout.check_urls) do
    check_urls[vim.api.nvim_buf_set_extmark(buf, ns_checks, row - 1, 0, {})] = url
  end
  states[buf].pr = pr
  states[buf].check_urls = check_urls
  vim.bo[buf].modified = false
end

--- The title and description as `buf` holds them now: the first line, and every line after the header.
---@param buf integer
---@return { title: string, body: string }
function M.edits(buf)
  local header_end = vim.api.nvim_buf_get_extmark_by_id(buf, ns_regions, HEADER_END, {})[1]
  return {
    title = vim.trim(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""),
    body = table.concat(vim.api.nvim_buf_get_lines(buf, header_end + 1, -1, false), "\n"),
  }
end

--- The URL of the check drawn on 1-based `row` of `buf`, if one is.
---@param buf integer
---@param row integer
---@return string?
function M.check_url(buf, row)
  local state = states[buf]
  local mark = vim.api.nvim_buf_get_extmarks(buf, ns_checks, { row - 1, 0 }, { row - 1, -1 }, {})[1]
  return state and mark and state.check_urls[mark[1]]
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
---@field body_row integer
---@field check_urls table<integer, string> row -> the check drawn there

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

-- Glyph and highlight per check state, in the order the summary counts them.
local CHECK_STATES = {
  { "failed", "\u{2717}", "DiagnosticError" },
  { "running", "\u{25cf}", "DiagnosticWarn" },
  { "skipped", "\u{2298}", "Comment" },
  { "passed", "\u{2713}", "DiagnosticOk" },
}

-- Checks listed one per row: those needing attention. The rest are only counted.
local LISTED = { failed = true, running = true }

--- `pr` laid out as the buffer shows it, as of `now`.
---@param pr nitpick.Pr
---@param now integer epoch seconds
---@return nitpick.PrLayout
function M.layout(pr, now)
  local lines, highlights, check_urls = {}, {}, {}
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

  row({ { pr.title } })
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
  return { lines = lines, highlights = highlights, body_row = body_row, check_urls = check_urls }
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
function M.setup()
  local function set_hl()
    for group, link in pairs({
      NitpickPrLabel = "Comment",
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
        M.attach(ev.buf, ref, require("nitpick.pr"))
      end
    end,
  })
  vim.api.nvim_create_user_command("NitpickPr", function(cmd)
    M.open(tonumber(cmd.args))
  end, { nargs = "?", desc = "Open a PR (default: the current branch's) as an editable buffer" })
end

return M
