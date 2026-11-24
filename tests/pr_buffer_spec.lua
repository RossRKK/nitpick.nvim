-- The PR buffer: the stack as its title block and the header, laid out from a
-- nitpick.Pr, and the title and description saved from the buffer through a
-- stand-in GitHub client.

local assert = require("luassert")
local pr_buffer = require("nitpick.pr_buffer")
local stack = require("nitpick.stack")

local NOW = 1800000000
local DAY = 86400

--- A PR with `fields` over a plain open one.
---@param fields table?
---@return nitpick.Pr
local function make_pr(fields)
  return vim.tbl_extend("force", {
    id = "PR_1",
    ref = { owner = "o", name = "r", number = 7 },
    url = "https://github.com/o/r/pull/7",
    title = "Add the thing",
    body = "Why.\n\nHow.",
    state = "open",
    author = { login = "ross", is_bot = false },
    head = "feat",
    base = "main",
    created_at = NOW - 14 * DAY,
    updated_at = NOW - 30,
    merge = "clean",
    checks = {},
  }, fields or {})
end

--- `p` alone, a stack of one.
local function alone(p)
  local own = stack.row_of(p)
  return assert(stack.order({ own }, own.number))
end

--- `p` in the middle of a three-PR stack: #9 above it, #3 below it on main.
local function stacked(p)
  return assert(stack.order({
    { number = 9, title = "Use the thing", head = "use", base = p.head, draft = true },
    stack.row_of(p),
    { number = 3, title = "Lay the ground", head = p.base, base = "main", draft = false, review = "approved", checks = "passed" },
  }, p.ref.number))
end

--- The virtual text `layout` draws on 1-based `row`, as one string per position.
local function virt(layout, row)
  local out = {}
  for _, d in ipairs(layout.decorations) do
    if d[1] == row then
      out[d[2].virt_text_pos] = table.concat(vim.tbl_map(function(c)
        return c[1]
      end, d[2].virt_text))
    end
  end
  return out
end

describe("pr_buffer.layout", function()
  it("is a stack of one over its base, then the header, then the description", function()
    local layout = pr_buffer.layout(make_pr(), alone(make_pr()), NOW)
    assert.same({
      "Add the thing",
      "\u{2570} main",
      "",
      "Status: Open  main \u{2190} feat",
      "Author: @ross  opened 2 weeks ago \u{b7} updated just now",
      "Merge: Clean",
      "Checks: none",
      "Why.",
      "",
      "How.",
    }, layout.lines)
    assert.equals(1, layout.title_row)
    assert.equals(8, layout.body_row)
    assert.equals("\u{25c9} #7  ", virt(layout, 1).inline)
  end)

  it("draws the stack top first, the PR's own row its title, each row its number and status", function()
    local p = make_pr({ base = "ground" })
    local layout = pr_buffer.layout(p, stacked(p), NOW)
    assert.same({ "Use the thing", "Add the thing", "Lay the ground", "\u{2570} main" }, vim.list_slice(layout.lines, 1, 4))
    assert.equals(2, layout.title_row)
    assert.equals("\u{25cb} #9  ", virt(layout, 1).inline)
    assert.equals("\u{25c9} #7  ", virt(layout, 2).inline)
    assert.equals("draft   ", virt(layout, 1).right_align)
    assert.equals("approved  \u{2713}", virt(layout, 3).right_align)
    assert.same({ 9, 7, 3 }, { layout.stack_rows[1].number, layout.stack_rows[2].number, layout.stack_rows[3].number })
  end)

  it("counts the checks by state and lists those failed, then running, each with its URL", function()
    local p = make_pr({
      checks = {
        { name = "ok", state = "passed", url = "u-ok" },
        { name = "slow", state = "running", url = "u-slow" },
        { name = "docs", state = "skipped" },
        { name = "lint", state = "failed", url = "u-lint" },
      },
    })
    local layout = pr_buffer.layout(p, alone(p), NOW)
    assert.equals("Checks: 1 failed \u{b7} 1 running \u{b7} 1 skipped \u{b7} 1 passed", layout.lines[7])
    assert.equals("  \u{2717} lint", layout.lines[8])
    assert.equals("  \u{25cf} slow", layout.lines[9])
    assert.same({ [8] = "u-lint", [9] = "u-slow" }, layout.check_urls)
    assert.equals("\u{2717}", virt(layout, 1).right_align:match("%S+$"), "the stack row rolls the checks up")
  end)

  it("drops the merge row once merged, and marks a bot author", function()
    local merged = make_pr({ state = "merged", author = { login = "mergify", is_bot = true } })
    merged.merge = nil
    local layout = pr_buffer.layout(merged, alone(merged), NOW)
    assert.equals("Status: Merged  main \u{2190} feat", layout.lines[4])
    assert.matches("^Author: @mergify %(bot%)", layout.lines[5])
    assert.equals("Checks: none", layout.lines[6])
  end)
end)

describe("pr_buffer.ago", function()
  it("names the largest whole span", function()
    assert.equals("just now", pr_buffer.ago(59))
    assert.equals("1 minute ago", pr_buffer.ago(60))
    assert.equals("3 hours ago", pr_buffer.ago(3 * 3600 + 59))
    assert.equals("1 day ago", pr_buffer.ago(DAY))
    assert.equals("2 weeks ago", pr_buffer.ago(14 * DAY))
    assert.equals("1 year ago", pr_buffer.ago(400 * DAY))
  end)
end)

describe("pr_buffer.uri", function()
  it("round-trips a PR's buffer name", function()
    local ref = { owner = "o", name = "r.nvim", number = 12 }
    assert.equals("nitpick://pr/o/r.nvim/12", pr_buffer.uri(ref))
    assert.same(ref, pr_buffer.parse_uri(pr_buffer.uri(ref)))
    assert.is_nil(pr_buffer.parse_uri("/tmp/file.lua"))
  end)
end)

describe("a PR buffer", function()
  local notified, notify, open
  before_each(function()
    notified, notify, open = {}, vim.notify, vim.ui.open
    vim.notify = function(msg, level)
      notified[#notified + 1] = { msg = msg, level = level }
    end
  end)
  after_each(function()
    vim.notify, vim.ui.open = notify, open
  end)

  --- A client serving `github` (the PR as GitHub has it, updated by saves, and
  --- the stack it is in, a stack of one when unset), and its update calls.
  local function client(github)
    local updates = {}
    return {
      fetch = function()
        return vim.deepcopy(github.pr)
      end,
      update = function(id, fields)
        updates[#updates + 1] = { id = id, fields = fields }
        github.pr = vim.tbl_extend("force", github.pr, fields)
        return true
      end,
      stack = function()
        return github.stack and github.stack(github.pr) or nil
      end,
    },
      updates
  end

  --- A buffer attached to `github`'s PR, shown in the current window.
  local function attached(github)
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, pr_buffer.uri(github.pr.ref) .. "-" .. buf)
    vim.api.nvim_win_set_buf(0, buf)
    local c, updates = client(github)
    pr_buffer.attach(buf, github.pr.ref, c)
    return buf, updates
  end

  it("renders the PR unmodified", function()
    local buf = attached({ pr = make_pr() })
    assert.equals("Add the thing", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
    assert.is_false(vim.bo[buf].modified)
    assert.equals("acwrite", vim.bo[buf].buftype)
  end)

  it("redraws with the stack once found", function()
    local p = make_pr({ base = "ground" })
    local buf = attached({ pr = p, stack = stacked })
    assert.same({ "Use the thing", "Add the thing", "Lay the ground" }, vim.api.nvim_buf_get_lines(buf, 0, 3, false))
  end)

  it("saves an edited description, and only that, with :w", function()
    local github = { pr = make_pr() }
    local buf, updates = attached(github)
    local last = vim.api.nvim_buf_line_count(buf)
    vim.api.nvim_buf_set_lines(buf, last - 1, last, false, { "How, better.", "And more." })
    vim.cmd.write()
    assert.same({ { id = "PR_1", fields = { body = "Why.\n\nHow, better.\nAnd more." } } }, updates)
    assert.equals("Why.\n\nHow, better.\nAnd more.", github.pr.body)
    assert.is_false(vim.bo[buf].modified)
  end)

  it("saves an edited title and description, both lines replaced and a row added to the header", function()
    local buf, updates = attached({ pr = make_pr() })
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "Add the better thing  " })
    vim.api.nvim_buf_set_lines(buf, 4, 4, false, { "stray line in the header" })
    local first_body = vim.fn.search([[^Why\.$]], "n")
    vim.api.nvim_buf_set_lines(buf, first_body - 1, first_body, false, { "Because." })
    pr_buffer.save(buf)
    assert.same({ { id = "PR_1", fields = { title = "Add the better thing", body = "Because.\n\nHow." } } }, updates)
  end)

  it("saves the title from the PR's own row in the middle of a stack, split lines joined", function()
    local p = make_pr({ base = "ground" })
    local buf, updates = attached({ pr = p, stack = stacked })
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "Add the", "better thing" })
    pr_buffer.save(buf)
    assert.same({ { id = "PR_1", fields = { title = "Add the better thing" } } }, updates)
  end)

  it("refuses to save over a description changed on GitHub since it loaded", function()
    local github = { pr = make_pr() }
    local buf, updates = attached(github)
    github.pr.body = "Someone else's words."
    vim.api.nvim_buf_set_lines(buf, -2, -1, false, { "Mine." })
    pr_buffer.save(buf)
    assert.same({}, updates)
    assert.matches("description changed on GitHub", notified[#notified].msg)
    assert.is_true(vim.bo[buf].modified, "the edits stay in the buffer")
  end)

  it("saves the title when only the description changed on GitHub", function()
    local github = { pr = make_pr() }
    local buf, updates = attached(github)
    github.pr.body = "Someone else's words."
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "New title" })
    pr_buffer.save(buf)
    assert.same({ { id = "PR_1", fields = { title = "New title" } } }, updates)
  end)

  it("refuses an empty title", function()
    local buf, updates = attached({ pr = make_pr() })
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "" })
    pr_buffer.save(buf)
    assert.same({}, updates)
    assert.matches("needs a title", notified[#notified].msg)
  end)

  it("opens the check under the cursor with gd, following the row if lines move above it", function()
    local opened
    vim.ui.open = function(url)
      opened = url
      return nil, nil
    end
    local buf = attached({ pr = make_pr({ checks = { { name = "lint", state = "failed", url = "u-lint" } } }) })
    vim.api.nvim_buf_set_lines(buf, 2, 2, false, { "", "" })
    vim.api.nvim_win_set_cursor(0, { 10, 0 })
    assert.equals("  \u{2717} lint", vim.api.nvim_get_current_line())
    vim.cmd("normal gd")
    assert.equals("u-lint", opened)
  end)

  it("opens another stack row's PR in the browser with gx", function()
    local opened
    vim.ui.open = function(url)
      opened = url
      return nil, nil
    end
    attached({ pr = make_pr({ base = "ground" }), stack = stacked })
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    vim.cmd("normal gx")
    assert.equals("https://github.com/o/r/pull/3", opened)
  end)

  it("hands <CR> on another stack row's PR to on_stack_select, and does nothing on its own row", function()
    local chosen
    pr_buffer.setup({
      on_stack_select = function(ref, row)
        chosen = { ref = ref, title = row.title }
      end,
    })
    attached({ pr = make_pr({ base = "ground" }), stack = stacked })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.cmd("normal \r")
    assert.is_nil(chosen)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd("normal \r")
    assert.same({ ref = { owner = "o", name = "r", number = 9 }, title = "Use the thing" }, chosen)
  end)
end)

describe("pr_buffer.buffer and refresh", function()
  local pr = require("nitpick.pr")
  local fetch, stack_fetch, fetches
  before_each(function()
    fetch, stack_fetch, fetches = pr.fetch, stack.fetch, 0
    pr.fetch = function(ref)
      fetches = fetches + 1
      return vim.tbl_extend("force", make_pr(), { ref = ref })
    end
    stack.fetch = function()
      return nil
    end
  end)
  after_each(function()
    pr.fetch, stack.fetch = fetch, stack_fetch
  end)

  it("makes one unlisted buffer per PR, loaded once", function()
    local ref = { owner = "o", name = "r", number = 41 }
    local buf, fresh = pr_buffer.buffer(ref)
    assert.is_true(fresh)
    assert.is_false(vim.bo[buf].buflisted)
    assert.equals("nitpick://pr/o/r/41", vim.api.nvim_buf_get_name(buf))
    assert.equals("Add the thing", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
    local again, fresh_again = pr_buffer.buffer(ref)
    assert.equals(buf, again)
    assert.is_false(fresh_again)
    assert.equals(1, fetches)
  end)

  it("refreshes from GitHub, but not over unsaved edits", function()
    local buf = pr_buffer.buffer({ owner = "o", name = "r", number = 42 })
    pr_buffer.refresh(buf)
    assert.equals(2, fetches)
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "My title" })
    pr_buffer.refresh(buf)
    assert.equals(2, fetches)
    assert.equals("My title", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
  end)
end)
