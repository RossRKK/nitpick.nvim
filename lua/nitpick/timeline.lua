-- A PR's conversation as threads: each comment on the PR, each review's
-- summary, each review thread on its lines, newest activity first.

local M = {}

-- The PR query's fields this module reads.
M.FIELDS = [[
      comments(last:100){ nodes{ id author{ __typename login } body createdAt viewerCanUpdate } }
      reviews(last:100){ nodes{ id author{ __typename login } body state submittedAt } }
      reviewThreads(last:100){ nodes{
        id isResolved isOutdated path line originalLine
        comments(first:100){ nodes{ id author{ __typename login } body createdAt diffHunk viewerCanUpdate } }
      } }
]]

---@alias nitpick.CommentKind "pr"|"review_comment"
---@alias nitpick.ThreadKind "comment"|"review"|"inline"

---@class nitpick.Comment
---@field id string GraphQL node id
---@field kind nitpick.CommentKind? which mutation edits it; nil for a review's summary
---@field author { login: string, is_bot: boolean }
---@field body string
---@field created_at integer epoch seconds
---@field can_edit boolean

---@class nitpick.Thread
---@field kind nitpick.ThreadKind
---@field id string? a review thread's node id, what a reply goes to
---@field comments nitpick.Comment[] oldest first
---@field latest integer epoch seconds of its newest comment
---@field review_state nitpick.ReviewState? a review's verdict
---@field path string? an inline thread's file
---@field line integer? an inline thread's line
---@field hunk string[]? the diff lines an inline thread is on, its own line last
---@field resolved boolean
---@field outdated boolean

-- A submitted review's verdict as nitpick names it; a review still pending isn't shown.
local REVIEW_STATES = {
  APPROVED = "approved",
  CHANGES_REQUESTED = "changes_requested",
  COMMENTED = "commented",
  DISMISSED = "commented",
}

-- Lines of an inline thread's diff hunk kept, ending at its own line.
local HUNK_LINES = 4

--- A pullRequest node's conversation, the newest activity first.
---@param p table
---@param epoch fun(iso: string): integer
---@return nitpick.Thread[]
function M.parse(p, epoch)
  local threads = {}
  local function comment(node, kind)
    local author = node.author ~= vim.NIL and node.author or { login = "ghost", __typename = "User" }
    return {
      id = node.id,
      kind = kind,
      author = { login = author.login, is_bot = author.__typename == "Bot" },
      body = ((node.body ~= vim.NIL and node.body) or ""):gsub("\r", ""),
      created_at = epoch(node.createdAt or node.submittedAt),
      can_edit = node.viewerCanUpdate == true,
    }
  end

  for _, node in ipairs(p.comments.nodes) do
    local c = comment(node, "pr")
    threads[#threads + 1] =
      { kind = "comment", comments = { c }, latest = c.created_at, resolved = false, outdated = false }
  end
  for _, node in ipairs(p.reviews.nodes) do
    local state = REVIEW_STATES[node.state]
    -- A review with no summary is only its inline threads, which are listed on their own.
    if state and node.submittedAt ~= vim.NIL and (node.body or "") ~= "" then
      local c = comment(node, nil)
      threads[#threads + 1] = {
        kind = "review",
        comments = { c },
        latest = c.created_at,
        review_state = state,
        resolved = false,
        outdated = false,
      }
    end
  end
  for _, node in ipairs(p.reviewThreads.nodes) do
    local comments = vim.tbl_map(function(n)
      return comment(n, "review_comment")
    end, node.comments.nodes)
    if #comments > 0 then
      local first = node.comments.nodes[1]
      threads[#threads + 1] = {
        kind = "inline",
        id = node.id,
        comments = comments,
        latest = comments[#comments].created_at,
        path = node.path,
        line = (node.line ~= vim.NIL and node.line) or (node.originalLine ~= vim.NIL and node.originalLine) or nil,
        hunk = M.hunk_tail(first.diffHunk ~= vim.NIL and first.diffHunk or ""),
        resolved = node.isResolved == true,
        outdated = node.isOutdated == true,
      }
    end
  end
  table.sort(threads, function(a, b)
    return a.latest > b.latest
  end)
  return threads
end

--- The last lines of a diff hunk, its @@ header dropped: the commented line and those just above it.
---@param hunk string
---@return string[]
function M.hunk_tail(hunk)
  local lines = vim.tbl_filter(function(l)
    return not l:match("^@@")
  end, vim.split(hunk:gsub("\r", ""), "\n", { plain = true, trimempty = true }))
  return vim.list_slice(lines, math.max(1, #lines - HUNK_LINES + 1))
end

--- `threads` without those whose every comment is by a bot not in `shown_bots`, and the logins of the bots left out.
---@param threads nitpick.Thread[]
---@param shown_bots table<string, boolean>
---@return nitpick.Thread[] kept, integer hidden threads, string[] the bots behind them, in order of first appearance
function M.without_bots(threads, shown_bots)
  local kept, hidden, seen, count = {}, {}, {}, 0
  for _, t in ipairs(threads) do
    local by_bots = vim.iter(t.comments):all(function(c)
      return c.author.is_bot and not shown_bots[c.author.login]
    end)
    if by_bots then
      count = count + 1
      for _, c in ipairs(t.comments) do
        if not seen[c.author.login] then
          seen[c.author.login] = true
          hidden[#hidden + 1] = c.author.login
        end
      end
    else
      kept[#kept + 1] = t
    end
  end
  return kept, count, hidden
end

return M
