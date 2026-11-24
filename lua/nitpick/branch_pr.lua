-- The open PR for the branch a checkout has out.

local async = require("nitpick.async")
local checkout = require("nitpick.checkout")
local github = require("nitpick.github")

local M = {}

-- Remembers a manual PR choice for a branch so we don't re-prompt:
-- {root, branch, number}.
M.choice = nil

--- The open PR for the branch checked out in `root`. Returns {number} or nil (no
--- PR, or the user dismissed the picker). Prompts once when a branch has several
--- open PRs and remembers the choice.
---@param root string
---@return { number: integer }?
function M.resolve(root)
  local branch = checkout.current_branch(root)
  if branch == "" then
    return nil
  end
  local prs = github.json(
    { "pr", "list", "--head", branch, "--state", "open", "--json", "number,title" },
    root
  )
  if not prs or #prs == 0 then
    return nil
  end

  local chosen
  if #prs == 1 then
    chosen = prs[1]
  elseif M.choice and M.choice.root == root and M.choice.branch == branch then
    for _, pr in ipairs(prs) do
      if pr.number == M.choice.number then
        chosen = pr
      end
    end
    chosen = chosen or prs[1]
  else
    local labels = {}
    for _, pr in ipairs(prs) do
      labels[#labels + 1] = ("#%d  %s"):format(pr.number, pr.title)
    end
    local idx = async.pick(labels, { prompt = "Multiple open PRs for this branch:" })
    if not idx then
      return nil
    end
    chosen = prs[idx]
    M.choice = { root = root, branch = branch, number = chosen.number }
  end
  return { number = chosen.number }
end

return M
