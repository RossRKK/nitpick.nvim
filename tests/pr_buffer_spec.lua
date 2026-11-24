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
    reviewers = {},
    checks = {},
    threads = {},
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

--- A comment by `login` `ago` seconds before NOW.
local function comment(login, ago, fields)
  return vim.tbl_extend("force", {
    id = "C_" .. login .. ago,
    kind = "pr",
    author = { login = login, is_bot = false },
    body = "Said " .. login .. ".",
    created_at = NOW - ago,
    can_edit = false,
  }, fields or {})
end

--- A PR with a conversation: your comment, an inline thread on the code, a resolved one and a bot's comment.
local function conversation()
  local mine = comment("ross", 60, { can_edit = true, body = "My first line.\nMy second line." })
  return make_pr({
    threads = {
      { kind = "comment", comments = { mine }, latest = mine.created_at, resolved = false, outdated = false },
      {
        kind = "inline",
        id = "T_1",
        path = "lua/x.lua",
        line = 12,
        hunk = { " local a = 1", "+local b = 2" },
        comments = {
          comment("bob", 3600, { kind = "review_comment", body = "Why b?" }),
          comment("ross", 1800, { kind = "review_comment", can_edit = true, body = "Because." }),
        },
        latest = NOW - 1800,
        resolved = false,
        outdated = false,
      },
      {
        kind = "inline",
        id = "T_2",
        path = "lua/y.lua",
        line = 3,
        hunk = { "-gone" },
        comments = { comment("bob", 7200, { kind = "review_comment" }) },
        latest = NOW - 7200,
        resolved = true,
        outdated = false,
      },
      {
        kind = "comment",
        comments = { comment("mergify", 9000, { author = { login = "mergify", is_bot = true } }) },
        latest = NOW - 9000,
        resolved = false,
        outdated = false,
      },
    },
  })
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
      "Reviewers: none",
      "Merge: Clean",
      "Checks: none",
      "Why.",
      "",
      "How.",
      "Conversation \u{b7} 0 threads",
      "",
    }, layout.lines)
    assert.equals(1, layout.title_row)
    assert.equals(9, layout.body_row)
    assert.equals("\u{25c9} #7  ", virt(layout, 1).inline)
  end)

  it("draws the stack top first, the PR's own row its title, each row its number and status", function()
    local p = make_pr({ base = "ground" })
    local layout = pr_buffer.layout(p, stacked(p), NOW, {})
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
    local layout = pr_buffer.layout(p, alone(p), NOW, {})
    assert.equals("Checks: 1 failed \u{b7} 1 running \u{b7} 1 skipped \u{b7} 1 passed", layout.lines[8])
    assert.equals("  \u{2717} lint", layout.lines[9])
    assert.equals("  \u{25cf} slow", layout.lines[10])
    assert.same({ [9] = "u-lint", [10] = "u-slow" }, layout.check_urls)
    assert.equals("\u{2717}", virt(layout, 1).right_align:match("%S+$"), "the stack row rolls the checks up")
  end)

  it("drops the merge row once merged, and marks a bot author", function()
    local merged = make_pr({ state = "merged", author = { login = "mergify", is_bot = true } })
    merged.merge = nil
    local layout = pr_buffer.layout(merged, alone(merged), NOW, {})
    assert.equals("Status: Merged  main \u{2190} feat", layout.lines[4])
    assert.matches("^Author: @mergify %(bot%)", layout.lines[5])
    assert.equals("Checks: none", layout.lines[7])
  end)

  it("lays the conversation out under the description, the code a thread is on above it", function()
    local p = conversation()
    local layout = pr_buffer.layout(p, alone(p), NOW, {})
    local from = layout.conversation_row
    assert.same({
      "Conversation \u{b7} 3 threads \u{b7} 1 by bots hidden (mergify)",
      "",
      "@ross  1 minute ago",
      "My first line.",
      "My second line.",
      "",
      "lua/x.lua:12",
      "\u{2502}  local a = 1",
      "\u{2502} +local b = 2",
      "@bob  1 hour ago",
      "Why b?",
      "@ross  30 minutes ago",
      "Because.",
      "",
      "lua/y.lua:3  resolved",
      "\u{2502} -gone",
      "@bob  2 hours ago",
      "Said bob.",
      "",
    }, vim.list_slice(layout.lines, from))
    assert.same({ from + 2, from + 4 }, { layout.comments[1][1], layout.comments[1][2] })
    assert.same({ from + 6, from + 12 }, { layout.threads[2][1], layout.threads[2][2] })
  end)

  it("shows a bot's comments when asked to", function()
    local p = conversation()
    local layout = pr_buffer.layout(p, alone(p), NOW, { mergify = true })
    assert.equals("Conversation \u{b7} 4 threads", layout.lines[layout.conversation_row])
  end)

  it("lists the reviewers under one label, names aligned, code owners shielded, a review's teams after it", function()
    local p = make_pr({
      reviewers = {
        { name = "acme/devs", kind = "team", code_owner = true, state = "pending", on_behalf_of = {} },
        { name = "bob", kind = "user", code_owner = false, state = "approved", on_behalf_of = { "acme/web" } },
      },
    })
    local layout = pr_buffer.layout(p, alone(p), NOW, {})
    assert.equals("Reviewers: \u{25cf} acme/devs \u{f132}  pending", layout.lines[6])
    assert.equals("           \u{2713} bob" .. (" "):rep(10) .. "approved  for acme/web", layout.lines[7])
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
      write_comment = function(how, id, body)
        updates[#updates + 1] = { how = how, id = id, body = body }
        for _, t in ipairs(github.pr.threads) do
          for _, c in ipairs(t.comments) do
            if c.id == id then
              c.body = body
            end
          end
        end
        return true
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
    local how = vim.fn.search([[^How\.$]], "n")
    vim.api.nvim_buf_set_lines(buf, how - 1, how, false, { "How, better.", "And more." })
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
    local how = vim.fn.search([[^How\.$]], "n")
    vim.api.nvim_buf_set_lines(buf, how - 1, how, false, { "Mine." })
    pr_buffer.save(buf)
    assert.same({}, updates)
    assert.matches("the description changed on GitHub", notified[#notified].msg)
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
    vim.api.nvim_win_set_cursor(0, { 11, 0 })
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

describe("a PR buffer's conversation", function()
  local notified, notify
  before_each(function()
    notified, notify = {}, vim.notify
    vim.notify = function(msg, level)
      notified[#notified + 1] = { msg = msg, level = level }
    end
  end)
  after_each(function()
    vim.notify = notify
  end)

  --- A buffer on `github`'s PR, and the writes made through its client.
  local function attached(github)
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, pr_buffer.uri(github.pr.ref) .. "-c" .. buf)
    vim.api.nvim_win_set_buf(0, buf)
    local writes = {}
    pr_buffer.attach(buf, github.pr.ref, {
      fetch = function()
        return vim.deepcopy(github.pr)
      end,
      update = function()
        return true
      end,
      stack = function()
        return nil
      end,
      write_comment = function(how, id, body)
        writes[#writes + 1] = { how = how, id = id, body = body }
        return true
      end,
    })
    return buf, writes
  end

  --- The 1-based row of the first line reading `text`.
  local function row_of(buf, text)
    for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      if l == text then
        return i
      end
    end
    error("no line " .. text)
  end

  it("saves an edit to your comment in place, the line replaced and another added", function()
    local buf, writes = attached({ pr = conversation() })
    local second = row_of(buf, "My second line.")
    vim.api.nvim_buf_set_lines(buf, second - 1, second, false, { "My better line.", "And one more." })
    pr_buffer.save(buf)
    assert.same({ { how = "pr", id = "C_ross60", body = "My first line.\nMy better line.\nAnd one more." } }, writes)
  end)

  it("saves your reply in a thread on the code as a review comment", function()
    local buf, writes = attached({ pr = conversation() })
    local because = row_of(buf, "Because.")
    vim.api.nvim_buf_set_lines(buf, because - 1, because, false, { "Because a needs company." })
    pr_buffer.save(buf)
    assert.same({ { how = "review_comment", id = "C_ross1800", body = "Because a needs company." } }, writes)
  end)

  it("leaves someone else's comment alone when its lines are edited", function()
    local buf, writes = attached({ pr = conversation() })
    local why = row_of(buf, "Why b?")
    vim.api.nvim_buf_set_lines(buf, why - 1, why, false, { "Rewritten." })
    pr_buffer.save(buf)
    assert.same({}, writes)
  end)

  it("refuses to save over your comment changed on GitHub since it loaded", function()
    local github = { pr = conversation() }
    local buf, writes = attached(github)
    github.pr.threads[1].comments[1].body = "Edited in the browser."
    local first = row_of(buf, "My first line.")
    vim.api.nvim_buf_set_lines(buf, first - 1, first, false, { "Edited here." })
    pr_buffer.save(buf)
    assert.same({}, writes)
    assert.matches("a comment of yours changed on GitHub", notified[#notified].msg)
  end)

  it("refuses to empty a comment", function()
    local buf, writes = attached({ pr = conversation() })
    local first = row_of(buf, "My first line.")
    vim.api.nvim_buf_set_lines(buf, first - 1, first + 1, false, {})
    pr_buffer.save(buf)
    assert.same({}, writes)
    assert.matches("can't be emptied", notified[#notified].msg)
  end)

  --- The first and last row of the closed fold at `row`, or nil when it's open.
  local function closed_at(row)
    local first = vim.fn.foldclosed(row)
    return first ~= -1 and { first, vim.fn.foldclosedend(row) } or nil
  end

  it("folds each thread, a resolved one closed and the rest open", function()
    local buf = attached({ pr = conversation() })
    local resolved = row_of(buf, "lua/y.lua:3  resolved")
    assert.same({ resolved, resolved + 3 }, closed_at(resolved))
    local open = row_of(buf, "lua/x.lua:12")
    assert.is_nil(closed_at(open))
    vim.cmd(open .. "foldclose")
    assert.same({ open, row_of(buf, "Because.") }, closed_at(open), "the fold covers the thread, its code and every comment")
  end)

  it("keeps the folds as they were left across a reload", function()
    local buf = attached({ pr = conversation() })
    vim.cmd(row_of(buf, "lua/y.lua:3  resolved") .. "foldopen")
    vim.cmd(row_of(buf, "lua/x.lua:12") .. "foldclose")
    pr_buffer.refresh(buf)
    assert.is_nil(closed_at(row_of(buf, "lua/y.lua:3  resolved")))
    assert.is_not_nil(closed_at(row_of(buf, "lua/x.lua:12")))
  end)

  it("folds the threads afresh in another window showing the buffer", function()
    local buf = attached({ pr = conversation() })
    vim.cmd("split")
    vim.api.nvim_win_set_buf(0, buf)
    assert.is_not_nil(closed_at(row_of(buf, "lua/y.lua:3  resolved")))
    vim.cmd("close")
  end)

  it("replies in a thread on the code from the compose box", function()
    local buf, writes = attached({ pr = conversation() })
    pr_buffer.reply(buf, row_of(buf, "Why b?"))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "On it." })
    vim.cmd("stopinsert")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-s>", true, false, true), "x", false)
    assert.same({ { how = "reply", id = "T_1", body = "On it." } }, writes)
  end)

  it("answers a comment on the PR with a new comment addressed to its author", function()
    local buf, writes = attached({ pr = conversation() })
    pr_buffer.reply(buf, row_of(buf, "My second line."))
    assert.same({ "@ross " }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "@ross Agreed." })
    vim.cmd("stopinsert")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-s>", true, false, true), "x", false)
    assert.same({ { how = "new", id = "PR_1", body = "@ross Agreed." } }, writes)
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
