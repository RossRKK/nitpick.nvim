-- Pure logic in nitpick/init.lua: the tree-decorator set (which paths light up
-- as "has comments" once live comments and unsent drafts are folded together),
-- the line remap across local edits, comment-to-comment navigation, how a
-- comment body is laid out for display, and which lines a review may anchor to.

local assert = require("luassert")
local comments = require("nitpick")

describe("comments.rebuild_marked", function()
  before_each(function()
    comments.by_path = {}
    comments.drafts = {}
    comments.marked = {}
  end)

  it("is empty when there are no comments or drafts", function()
    comments.rebuild_marked("/repo")
    assert.same({}, comments.marked)
  end)

  -- The decorator paints directories too, so an icon on a nested file has to
  -- propagate up every ancestor for the collapsed tree to show it.
  it("marks a commented file and every ancestor up to the root", function()
    comments.by_path = { ["src/a/b.lua"] = { { line = 1 } } }
    comments.rebuild_marked("/repo")

    assert.same({
      ["/repo"] = true,
      ["/repo/src"] = true,
      ["/repo/src/a"] = true,
      ["/repo/src/a/b.lua"] = true,
    }, comments.marked)
  end)

  it("marks a file at the repo root", function()
    comments.by_path = { ["README.md"] = { { line = 1 } } }
    comments.rebuild_marked("/repo")

    assert.same({ ["/repo"] = true, ["/repo/README.md"] = true }, comments.marked)
  end)

  it("marks drafts as well as live comments", function()
    comments.drafts = { ["src/draft.lua"] = { { line = 2, body = "hi" } } }
    comments.rebuild_marked("/repo")

    assert.is_true(comments.marked["/repo/src/draft.lua"])
    assert.is_true(comments.marked["/repo/src"])
  end)

  -- Discarding the last draft on a file leaves an empty list behind rather than
  -- removing the key; that file must stop being marked.
  it("ignores a file whose draft list is empty", function()
    comments.drafts = { ["src/empty.lua"] = {} }
    comments.rebuild_marked("/repo")

    assert.same({}, comments.marked)
  end)

  it("unions live comments and drafts", function()
    comments.by_path = { ["src/live.lua"] = { { line = 1 } } }
    comments.drafts = { ["docs/draft.md"] = { { line = 1, body = "hi" } } }
    comments.rebuild_marked("/repo")

    assert.is_true(comments.marked["/repo/src/live.lua"])
    assert.is_true(comments.marked["/repo/docs/draft.md"])
    assert.is_true(comments.marked["/repo"])
  end)

  it("replaces the previous set rather than accumulating", function()
    comments.by_path = { ["gone.lua"] = { { line = 1 } } }
    comments.rebuild_marked("/repo")
    assert.is_true(comments.marked["/repo/gone.lua"])

    comments.by_path = { ["kept.lua"] = { { line = 1 } } }
    comments.rebuild_marked("/repo")

    assert.is_nil(comments.marked["/repo/gone.lua"])
    assert.is_true(comments.marked["/repo/kept.lua"])
  end)

  it("normalizes a root given with a trailing slash", function()
    comments.by_path = { ["a.lua"] = { { line = 1 } } }
    comments.rebuild_marked("/repo/")

    assert.is_true(comments.marked["/repo/a.lua"])
  end)
end)

describe("nitpick surface", function()
  -- The keymaps and user commands bind straight to these; a rename or a
  -- require-time break should fail here rather than at first keypress.
  it("exposes the surface the keymaps bind to", function()
    for _, fn in ipairs({
      "comment",
      "reply",
      "resolve",
      "edit",
      "discard_draft",
      "submit",
      "yank_drafts",
      "export_drafts",
      "set_shown",
      "refresh",
      "has_comments",
      "jump_comment",
      "statusline",
      "setup",
    }) do
      assert.equals("function", type(comments[fn]), fn .. "() is missing")
    end
  end)
end)

describe("nitpick.remap_line", function()
  local remap = comments.remap_line

  -- Hunk tuples below are the real {start_a, count_a, start_b, count_b} that
  -- vim.diff(..., {result_type="indices"}) emits for the described edit against a
  -- five-line base "a\nb\nc\nd\ne\n" -- so these cases pin the convention, not
  -- just our arithmetic.

  it("is the identity with no changes", function()
    local row, tracked = remap({}, 3)
    assert.equals(3, row)
    assert.is_true(tracked)
  end)

  it("shifts a line down past an insertion above it", function()
    -- two lines inserted at the top: {0,0,1,2}
    local row, tracked = remap({ { 0, 0, 1, 2 } }, 3)
    assert.equals(5, row)
    assert.is_true(tracked)
  end)

  it("shifts a line up past a deletion above it", function()
    -- line 2 deleted: {2,1,1,0}
    local row, tracked = remap({ { 2, 1, 1, 0 } }, 3)
    assert.equals(2, row)
    assert.is_true(tracked)
  end)

  -- The property the user cared about: a line that only MOVED is tracked, never
  -- reported as drifted.
  it("tracks (not drifts) a moved-but-unchanged line", function()
    local _, tracked = remap({ { 0, 0, 1, 2 } }, 4)
    assert.is_true(tracked)
  end)

  it("leaves a line untouched when the insertion is below it", function()
    -- one line inserted after line 2: {2,0,3,1}
    assert.equals(1, remap({ { 2, 0, 3, 1 } }, 1))
    assert.equals(2, remap({ { 2, 0, 3, 1 } }, 2)) -- insertion sits after line 2
    assert.equals(4, remap({ { 2, 0, 3, 1 } }, 3)) -- line 3 pushed down one
  end)

  it("reports a line inside a change as untracked (drifted)", function()
    -- line 3 modified in place: {3,1,3,1}
    local row, tracked = remap({ { 3, 1, 3, 1 } }, 3)
    assert.is_false(tracked)
    assert.equals(3, row) -- anchored at the new hunk position
  end)

  it("accumulates deltas across several hunks below the line", function()
    -- +2 at top and -1 at old line 2, seen by a line after both.
    local row, tracked = remap({ { 0, 0, 1, 2 }, { 2, 1, 3, 0 } }, 4)
    assert.equals(5, row) -- 4 + 2 (insert) - 1 (delete)
    assert.is_true(tracked)
  end)
end)

describe("nitpick.wrap_text", function()
  local wrap = comments.wrap_text

  -- The bug this covers: bodies used to be rebuilt word by word, so every run of
  -- whitespace collapsed to one space and a pasted snippet lost its shape.
  it("keeps indentation and inner spacing on a line that fits", function()
    assert.same({ "    if x then      -- aligned" }, wrap("    if x then      -- aligned"))
  end)

  it("expands tabs to a fixed stop rather than dropping them", function()
    assert.same({ "    x = 1" }, wrap("\tx = 1"))
    assert.same({ "a   b" }, wrap("a\tb"))
  end)

  it("trims trailing whitespace and keeps a blank line blank", function()
    assert.same({ "" }, wrap(""))
    assert.same({ "" }, wrap("   "))
    assert.same({ "code" }, wrap("code   "))
  end)

  it("wraps a long line at a space, indenting the continuation to match", function()
    local lines = wrap("  " .. string.rep("word ", 30))
    assert.is_true(#lines > 1)
    assert.equals("  word word", lines[1]:sub(1, 11))
    for _, l in ipairs(lines) do
      assert.is_true(#l <= 80)
      assert.equals("  ", l:sub(1, 2)) -- continuations carry the original indent
    end
  end)

  it("hard-breaks a token too long to ever fit", function()
    local lines = wrap(string.rep("u", 190))
    assert.same({ string.rep("u", 80), string.rep("u", 80), string.rep("u", 30) }, lines)
  end)

  -- Verbatim (a line inside a code fence) must never reflow: an over-long line
  -- is chopped, so every character stays where the author put it.
  it("chops but never reflows a verbatim line", function()
    local text = "    " .. string.rep("a", 40) .. "  " .. string.rep("b", 50)
    local lines = wrap(text, true)
    assert.same(text, table.concat(lines))
    assert.equals(80, #lines[1])
  end)
end)

describe("nitpick.body_lines", function()
  local body_lines = comments.body_lines

  it("keeps a fenced snippet exactly as written", function()
    assert.same({
      "look:",
      "```lua",
      "if x then",
      "    y  =  1",
      "end",
      "```",
    }, body_lines("look:\n```lua\nif x then\n\ty  =  1\nend\n```"))
  end)

  it("still reflows prose outside the fence", function()
    local lines = body_lines(string.rep("word ", 40))
    assert.is_true(#lines > 1)
  end)

  it("does not close a fence on an info-string line inside it", function()
    local lines = body_lines("```\n```lua still code\n```\nafter")
    assert.same({ "```", "```lua still code", "```", "after" }, lines)
  end)

  it("handles an unterminated fence and CRLF bodies", function()
    assert.same({ "```", "  raw" }, body_lines("```\r\n  raw"))
  end)

  it("is empty-safe", function()
    assert.same({ "" }, body_lines(nil))
  end)
end)

describe("nitpick.drafts_markdown", function()
  local md = comments.drafts_markdown

  local entries = {
    { path = "src/a.lua", line = 12, body = "nit: name this" },
    { path = "src/a.lua", line = 40, start_line = 36, body = "this block\nis suspect" },
    { path = "src/b.lua", line = 3, body = "```lua\n    keep  spacing\n```" },
  }

  it("heads the document with what was being reviewed", function()
    local out = md(entries, { branch = "feat/x", commit = "abcdef1234", when = "2026-08-11 09:00" })
    assert.equals("# Review drafts — feat/x @ abcdef1", out[1])
    assert.equals("3 comment(s), saved 2026-08-11 09:00", out[3])
  end)

  it("groups by file, one subsection per comment, ranges spelled out", function()
    local out = table.concat(md(entries), "\n")
    assert.equals(1, select(2, out:gsub("## src/a%.lua", ""))) -- one heading for two comments
    assert.is_truthy(out:find("### L12\n\nnit: name this", 1, true))
    assert.is_truthy(out:find("### L36-L40\n\nthis block\nis suspect", 1, true))
    assert.is_truthy(out:find("## src/b%.lua"))
  end)

  -- The point of keeping them: a body must survive the round trip untouched.
  it("writes bodies verbatim, including code blocks", function()
    local out = table.concat(md(entries), "\n")
    assert.is_truthy(out:find("```lua\n    keep  spacing\n```", 1, true))
  end)

  it("works without any metadata", function()
    assert.equals("# Review drafts", md(entries)[1])
    assert.equals("3 comment(s)", md(entries)[3])
  end)
end)

describe("nitpick.diff_line_sets", function()
  local sets = comments.diff_line_sets

  -- A unified diff as `gh pr diff` / `git diff base...head` emit it, including
  -- content lines that look like file headers and a deleted file (new path
  -- /dev/null), whose hunks must not leak into the previous file's sets.
  local diff = table.concat({
    "diff --git a/src/a.lua b/src/a.lua",
    "index 1111111..2222222 100644",
    "--- a/src/a.lua",
    "+++ b/src/a.lua",
    "@@ -10,3 +10,4 @@ function foo()",
    " context",
    "-gone",
    "+added",
    "+--- not a header",
    "diff --git a/old.txt b/old.txt",
    "deleted file mode 100644",
    "--- a/old.txt",
    "+++ /dev/null",
    "@@ -1,2 +0,0 @@",
    "-one",
    "-two",
  }, "\n")

  it("marks added and context lines on the right, deleted and context on the left", function()
    local a = sets(diff)["src/a.lua"]
    assert.same({ [10] = true, [11] = true, [12] = true }, a.right) -- context, added, added
    assert.same({ [10] = true, [11] = true }, a.left) -- context, deleted
  end)

  it("keeps a deleted file (and its hunks) out of the sets", function()
    local files = sets(diff)
    assert.is_nil(files["old.txt"])
    assert.is_nil(files["/dev/null"])
    assert.is_nil(sets(diff)["src/a.lua"].left[1]) -- old.txt's deletions didn't leak
  end)

  it("is empty for an empty diff", function()
    assert.same({}, sets(""))
  end)
end)

describe("nitpick.next_anchor", function()
  local next_anchor = comments.next_anchor
  local rows = { 3, 7, 12 }

  it("finds the next row strictly past the cursor", function()
    assert.equals(7, next_anchor(rows, 3, 1)) -- on an anchor: skips to the next
    assert.equals(7, next_anchor(rows, 5, 1))
    assert.equals(3, next_anchor(rows, 1, 1))
  end)

  it("finds the previous row strictly before the cursor", function()
    assert.equals(3, next_anchor(rows, 7, -1)) -- on an anchor: skips to the prev
    assert.equals(7, next_anchor(rows, 9, -1))
    assert.equals(12, next_anchor(rows, 99, -1))
  end)

  it("does not wrap: nil when nothing lies that way", function()
    assert.is_nil(next_anchor(rows, 12, 1))
    assert.is_nil(next_anchor(rows, 3, -1))
    assert.is_nil(next_anchor({}, 5, 1))
  end)
end)
