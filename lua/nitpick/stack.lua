-- The stack a PR is in: open PRs chained through their base branches, the way
-- GitHub models a stack and retargets it as the bottom merges.

local github = require("nitpick.github")
local pr = require("nitpick.pr")

local M = {}

---@class nitpick.StackPr
---@field number integer
---@field title string
---@field head string
---@field base string
---@field draft boolean
---@field review nitpick.ReviewDecision?
---@field checks nitpick.CheckState? the head commit's checks rolled up; nil with none

---@class nitpick.Stack
---@field rows nitpick.StackPr[] top of the stack first, each PR above the one it targets
---@field current integer the index in rows of the PR the stack was found from
---@field trunk string the branch the bottom PR targets

-- Bounds on the walk, against a runaway chain of PRs.
local MAX_LEVELS = 10
local MAX_PRS = 30

local FIELDS = [[
  number title isDraft headRefName baseRefName reviewDecision
  commits(last:1){ nodes{ commit{ statusCheckRollup{ state } } } }
]]

--- The stack `current` is in, found on GitHub: down its bases to the trunk and
--- up from every PR on the way, so siblings forked off a lower PR are in it too.
--- Each level of the walk, both ways, is one query. Nil when a lookup fails.
--- Must run inside a coroutine.
---@param ref nitpick.PrRef
---@param current nitpick.StackPr
---@return nitpick.Stack?
function M.fetch(ref, current)
  local found, count = { [current.number] = current }, 1
  local asked = { head = { [current.head] = true, [current.base] = true }, base = { [current.head] = true } }
  local frontier = { head = { current.base }, base = { current.head } }
  for _ = 1, MAX_LEVELS do
    if (#frontier.head == 0 and #frontier.base == 0) or count >= MAX_PRS then
      break
    end
    local answers = M.open_prs(ref, frontier)
    if not answers then
      return nil
    end
    local next_frontier = { head = {}, base = {} }
    local function ask(by, branch)
      if not asked[by][branch] then
        asked[by][branch] = true
        table.insert(next_frontier[by], branch)
      end
    end
    for by, lists in pairs(answers) do
      for _, prs in ipairs(lists) do
        -- A branch is the head of one open PR; below, only that one is followed.
        for i, p in ipairs(prs) do
          if by == "base" or i == 1 then
            if not found[p.number] then
              found[p.number], count = p, count + 1
            end
            ask("head", p.base)
            ask("base", p.head)
          end
        end
      end
    end
    frontier = next_frontier
  end
  return M.order(vim.tbl_values(found), current.number)
end

--- The open PRs from each branch in `branches.head` and onto each in
--- `branches.base`, in one query: a list per branch, in the order asked.
--- Must run inside a coroutine.
---@param ref nitpick.PrRef
---@param branches { head: string[], base: string[] }
---@return { head: nitpick.StackPr[][], base: nitpick.StackPr[][] }?
function M.open_prs(ref, branches)
  local params, fields = { "$owner:String!", "$name:String!" }, {}
  local values = { "-F", "owner=" .. ref.owner, "-F", "name=" .. ref.name }
  for _, by in ipairs({ "head", "base" }) do
    for i, branch in ipairs(branches[by]) do
      local var = ("%s%d"):format(by, i)
      params[#params + 1] = ("$%s:String!"):format(var)
      fields[#fields + 1] = ("%s: pullRequests(states:OPEN,first:20,%sRefName:$%s){ nodes{ %s } }"):format(
        var,
        by,
        var,
        FIELDS
      )
      vim.list_extend(values, { "-f", ("%s=%s"):format(var, branch) })
    end
  end
  local query = ("query(%s){ repository(owner:$owner,name:$name){ %s } }"):format(
    table.concat(params, ","),
    table.concat(fields, " ")
  )
  local reply = github.json(vim.list_extend({ "api", "graphql", "-f", "query=" .. query }, values))
  if not reply then
    return nil
  end
  local repository = reply.data.repository
  local answers = { head = {}, base = {} }
  for _, by in ipairs({ "head", "base" }) do
    for i in ipairs(branches[by]) do
      answers[by][i] = vim.tbl_map(M.parse_node, repository[("%s%d"):format(by, i)].nodes)
    end
  end
  return answers
end

-- A commit's statusCheckRollup state, as a check state.
local ROLLUP_STATES = {
  SUCCESS = "passed",
  FAILURE = "failed",
  ERROR = "failed",
  PENDING = "running",
  EXPECTED = "running",
}

--- `p` as a row of its own stack, before the stack is known.
---@param p nitpick.Pr
---@return nitpick.StackPr
function M.row_of(p)
  local states = {}
  for _, c in ipairs(p.checks) do
    states[c.state] = true
  end
  return {
    number = p.ref.number,
    title = p.title,
    head = p.head,
    base = p.base,
    draft = p.state == "draft",
    review = p.review,
    checks = (states.failed and "failed") or (states.running and "running") or (states.passed and "passed") or nil,
  }
end

--- A pullRequest node, as asked for by FIELDS (reviewDecision optional), as a stack row.
---@param node table
---@return nitpick.StackPr
function M.parse_node(node)
  local commit = node.commits and node.commits.nodes[1] and node.commits.nodes[1].commit
  local rollup = commit and commit.statusCheckRollup
  return {
    number = node.number,
    title = node.title,
    head = node.headRefName,
    base = node.baseRefName,
    draft = node.isDraft == true,
    review = pr.REVIEW_DECISIONS[node.reviewDecision],
    checks = rollup and rollup ~= vim.NIL and ROLLUP_STATES[rollup.state] or nil,
  }
end

--- The stack PR `current` is in among `prs`: every PR chained to the bottom of
--- its base chain, top first, a fork's branches together, the newest above. A PR
--- standing alone is a stack of one. Nil when `current` isn't among `prs`.
---@param prs nitpick.StackPr[]
---@param current integer
---@return nitpick.Stack?
function M.order(prs, current)
  local by_head, on, start = {}, {}, nil
  for _, p in ipairs(prs) do
    by_head[p.head] = p
    on[p.base] = on[p.base] or {}
    table.insert(on[p.base], p)
    if p.number == current then
      start = p
    end
  end
  if not start then
    return nil
  end
  -- Seen guards a base cycle, which GitHub allows between open PRs.
  local bottom, seen = start, { [start] = true }
  while by_head[bottom.base] and not seen[by_head[bottom.base]] do
    bottom = by_head[bottom.base]
    seen[bottom] = true
  end

  local rows, placed = {}, {}
  local function place(p)
    placed[p] = true
    local children = vim.tbl_filter(function(c)
      return not placed[c]
    end, on[p.head] or {})
    table.sort(children, function(a, b)
      return a.number > b.number
    end)
    for _, child in ipairs(children) do
      place(child)
    end
    rows[#rows + 1] = p
  end
  place(bottom)
  local index
  for i, p in ipairs(rows) do
    if p.number == current then
      index = i
    end
  end
  return { rows = rows, current = index, trunk = bottom.base }
end

return M
