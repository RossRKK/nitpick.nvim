-- A pull request as nitpick shows it, read from and written to GitHub.

local async = require("nitpick.async")
local github = require("nitpick.github")

local M = {}

---@class nitpick.PrRef
---@field owner string
---@field name string
---@field number integer

---@alias nitpick.PrState "open"|"draft"|"merged"|"closed"
---@alias nitpick.MergeState "clean"|"conflicts"|"blocked"|"behind"|"unstable"|"draft"|"unknown"
---@alias nitpick.CheckState "failed"|"running"|"skipped"|"passed"

---@class nitpick.Check
---@field name string
---@field state nitpick.CheckState
---@field url string?

---@class nitpick.Pr
---@field id string GraphQL node id, the handle mutations take
---@field ref nitpick.PrRef
---@field url string
---@field title string
---@field body string
---@field state nitpick.PrState
---@field author { login: string, is_bot: boolean }
---@field head string
---@field base string
---@field created_at integer epoch seconds
---@field updated_at integer epoch seconds
---@field merge nitpick.MergeState? nil once merged or closed
---@field checks nitpick.Check[]

M.QUERY = [[
query($owner:String!,$name:String!,$number:Int!){
  repository(owner:$owner,name:$name){
    pullRequest(number:$number){
      id number url title body state isDraft createdAt updatedAt headRefName baseRefName
      author{ __typename login }
      mergeable mergeStateStatus
      commits(last:1){ nodes{ commit{ statusCheckRollup{ contexts(first:100){ nodes{
        __typename
        ... on CheckRun{ name status conclusion detailsUrl }
        ... on StatusContext{ context state targetUrl }
      } } } } } }
    }
  }
}
]]

--- Fetch `ref`. Must run inside a coroutine.
---@param ref nitpick.PrRef
---@return nitpick.Pr? pr, string? err
function M.fetch(ref)
  -- stylua: ignore
  local reply, err = github.json({
    "api", "graphql",
    "-f", "query=" .. M.QUERY,
    "-F", "owner=" .. ref.owner,
    "-F", "name=" .. ref.name,
    "-F", "number=" .. ref.number,
  })
  if not reply then
    return nil, err
  end
  local ok, pr = pcall(M.parse, reply, ref)
  if not ok then
    return nil, "unexpected reply: " .. tostring(pr)
  end
  return pr
end

--- Set the title and/or body of the PR with node id `id`. Must run inside a coroutine.
---@param id string
---@param fields { title: string?, body: string? }
---@return boolean ok, string? err
function M.update(id, fields)
  local params, inputs, values = { "$id:ID!" }, { "pullRequestId:$id" }, { "-f", "id=" .. id }
  for _, field in ipairs({ "title", "body" }) do
    if fields[field] then
      params[#params + 1] = ("$%s:String!"):format(field)
      inputs[#inputs + 1] = ("%s:$%s"):format(field, field)
      vim.list_extend(values, { "-f", ("%s=%s"):format(field, fields[field]) })
    end
  end
  local mutation = ("mutation(%s){ updatePullRequest(input:{%s}){ pullRequest{ id } } }"):format(
    table.concat(params, ","),
    table.concat(inputs, ",")
  )
  local obj = async.sh(vim.list_extend({ "gh", "api", "graphql", "-f", "query=" .. mutation }, values))
  if obj.code ~= 0 then
    return false, github.error_text(obj)
  end
  return true
end

--- The PR `number` in the GitHub repo `root` is a checkout of. Must run inside a coroutine.
---@param root string
---@param number integer
---@return nitpick.PrRef? ref, string? err
function M.ref_for(root, number)
  local repo, err = github.json({ "repo", "view", "--json", "owner,name" }, root)
  if not repo then
    return nil, err
  end
  return { owner = repo.owner.login, name = repo.name, number = number }
end

-- GitHub's merge state per mergeStateStatus.
local MERGE_STATES = {
  CLEAN = "clean",
  HAS_HOOKS = "clean",
  DIRTY = "conflicts",
  BLOCKED = "blocked",
  BEHIND = "behind",
  UNSTABLE = "unstable",
  DRAFT = "draft",
  UNKNOWN = "unknown",
}

-- A finished CheckRun's state per conclusion; one not finished is running.
local RUN_CONCLUSIONS = {
  SUCCESS = "passed",
  NEUTRAL = "skipped",
  SKIPPED = "skipped",
  FAILURE = "failed",
  TIMED_OUT = "failed",
  CANCELLED = "failed",
  ACTION_REQUIRED = "failed",
  STARTUP_FAILURE = "failed",
  STALE = "failed",
}

-- A commit status's state per StatusContext state.
local STATUS_STATES = {
  SUCCESS = "passed",
  PENDING = "running",
  EXPECTED = "running",
  FAILURE = "failed",
  ERROR = "failed",
}

--- `reply`, the decoded answer to M.QUERY, as a nitpick.Pr.
---@param reply table
---@param ref nitpick.PrRef
---@return nitpick.Pr
function M.parse(reply, ref)
  local p = reply.data.repository.pullRequest
  local state = p.state == "OPEN" and (p.isDraft and "draft" or "open") or p.state:lower()
  local author = p.author ~= vim.NIL and p.author or { login = "ghost", __typename = "User" }
  return {
    id = p.id,
    ref = ref,
    url = p.url,
    title = p.title,
    body = (p.body or ""):gsub("\r", ""),
    state = state,
    author = { login = author.login, is_bot = author.__typename == "Bot" },
    head = p.headRefName,
    base = p.baseRefName,
    created_at = M.epoch(p.createdAt),
    updated_at = M.epoch(p.updatedAt),
    merge = (state == "open" or state == "draft") and (MERGE_STATES[p.mergeStateStatus] or "unknown")
      or nil,
    checks = M.parse_checks(p.commits),
  }
end

--- The checks on the PR's head commit, from the reply's commits(last:1).
---@param commits table
---@return nitpick.Check[]
function M.parse_checks(commits)
  local commit = commits.nodes[1] and commits.nodes[1].commit
  local rollup = commit and commit.statusCheckRollup
  if not rollup or rollup == vim.NIL then
    return {}
  end
  local checks = {}
  for _, c in ipairs(rollup.contexts.nodes) do
    if c.__typename == "CheckRun" then
      checks[#checks + 1] = {
        name = c.name,
        state = c.status ~= "COMPLETED" and "running" or RUN_CONCLUSIONS[c.conclusion] or "failed",
        url = c.detailsUrl ~= vim.NIL and c.detailsUrl or nil,
      }
    else
      checks[#checks + 1] = {
        name = c.context,
        state = STATUS_STATES[c.state] or "failed",
        url = c.targetUrl ~= vim.NIL and c.targetUrl or nil,
      }
    end
  end
  return checks
end

--- Seconds since the epoch of a UTC ISO 8601 time as GitHub writes it ("2026-11-14T17:09:48Z").
---@param iso string
---@return integer
function M.epoch(iso)
  local y, mo, d, h, mi, s = iso:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
  -- Days from the civil date (Howard Hinnant's days_from_civil): os.time reads a date as local time.
  y = mo <= 2 and y - 1 or y
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * (mo + (mo > 2 and -3 or 9)) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  local days = era * 146097 + doe - 719468
  return days * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(s)
end

return M
