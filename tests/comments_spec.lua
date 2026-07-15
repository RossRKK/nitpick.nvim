-- Pure logic in nitpick/init.lua: the tree-decorator set (which paths light up
-- as "has comments" once live comments and unsent drafts are folded together),
-- the line remap across local edits, and comment-to-comment navigation.

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
