-- A PR's conversation as threads, from a recorded GitHub reply
-- (tests/fixtures/pr_conversation.json: neovim/neovim#42932).

local assert = require("luassert")
local pr = require("nitpick.pr")
local timeline = require("nitpick.timeline")

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")

--- The recorded PR node.
local function recorded()
  local reply = vim.json.decode(table.concat(vim.fn.readfile(here .. "/fixtures/pr_conversation.json"), "\n"))
  return reply.data.repository.pullRequest
end

--- A comment by `login`, a bot when `bot`, at `at`.
local function comment(login, at, bot)
  return { id = login .. at, kind = "pr", author = { login = login, is_bot = bot == true }, body = "hi", created_at = at, can_edit = false }
end

--- A thread of `comments`.
local function thread(comments)
  return { kind = "comment", comments = comments, latest = comments[#comments].created_at, resolved = false, outdated = false }
end

describe("timeline.parse", function()
  it("lists comments on the PR and threads on its lines, the newest activity first", function()
    local threads = timeline.parse(recorded(), pr.epoch)
    assert.same(
      {
        "comment justinmk",
        "inline runtime/doc/news.txt",
        "comment ishianecho",
        "comment barrettruth",
        "inline runtime/lua/vim/net/_ssh.lua",
        "inline runtime/lua/vim/net/_ssh.lua",
        "inline test/functional/lua/ssh_spec.lua",
      },
      vim.tbl_map(function(t)
        return t.kind .. " " .. (t.path or t.comments[1].author.login)
      end, threads)
    )
    assert.equals(1795350862, threads[1].latest)
  end)

  it("reads an inline thread's place, state and the end of its diff hunk", function()
    local threads = timeline.parse(recorded(), pr.epoch)
    local open = threads[5]
    assert.equals(12, open.line)
    assert.is_false(open.resolved)
    assert.is_false(open.outdated)
    assert.equals("+local ssh_dir = '~/.ssh'", open.hunk[#open.hunk])
    assert.equals("review_comment", open.comments[1].kind)
    local stale = threads[7]
    assert.equals(84, stale.line, "an outdated thread keeps its original line")
    assert.is_true(stale.resolved)
    assert.is_true(stale.outdated)
  end)

  it("reads a review's summary as a thread of its own, and leaves out a review without one", function()
    local p = recorded()
    p.reviews.nodes[1].body = "Looks good once the test lands."
    local reviews = vim.tbl_filter(function(t)
      return t.kind == "review"
    end, timeline.parse(p, pr.epoch))
    assert.equals(1, #reviews)
    assert.equals("commented", reviews[1].review_state)
    assert.equals("Looks good once the test lands.", reviews[1].comments[1].body)
    assert.is_nil(reviews[1].comments[1].kind, "a summary isn't edited as a comment")
  end)

  it("marks a comment yours to edit only when you wrote it and GitHub lets you", function()
    local p = recorded()
    -- A maintainer may update anyone's comment; only their own is theirs to edit.
    for _, node in ipairs(p.comments.nodes) do
      node.viewerCanUpdate = true
    end
    p.comments.nodes[1].viewerDidAuthor = true
    p.comments.nodes[2].viewerDidAuthor = true
    p.comments.nodes[2].viewerCanUpdate = false
    local mine = vim.tbl_filter(function(t)
      return t.comments[1].can_edit
    end, timeline.parse(p, pr.epoch))
    assert.equals(1, #mine)
    assert.equals(p.comments.nodes[1].id, mine[1].comments[1].id)
  end)
end)

describe("timeline.hunk_tail", function()
  it("keeps the last four lines, the @@ header dropped", function()
    assert.same({ "b", "+c", "-d", " e" }, timeline.hunk_tail("@@ -1,5 +1,5 @@\na\nb\n+c\n-d\n e"))
    assert.same({ "+x" }, timeline.hunk_tail("@@ -0,0 +1 @@\n+x"))
  end)
end)

describe("timeline.without_bots", function()
  it("leaves out threads only bots wrote, counting them and naming the bots", function()
    local kept, hidden, bots = timeline.without_bots({
      thread({ comment("mergify", 1, true) }),
      thread({ comment("ross", 2) }),
      thread({ comment("github-actions", 3, true), comment("mergify", 4, true) }),
      thread({ comment("codecov", 5, true), comment("ross", 6) }),
    }, {})
    assert.equals(2, #kept)
    assert.equals(2, hidden)
    assert.same({ "mergify", "github-actions" }, bots)
  end)

  it("keeps the bots asked for", function()
    local kept, hidden = timeline.without_bots({ thread({ comment("claude", 1, true) }) }, { claude = true })
    assert.equals(1, #kept)
    assert.equals(0, hidden)
  end)
end)
