-- A PR read from GitHub's GraphQL reply (recorded in tests/fixtures), and the
-- mutation that saves its title and description.

local assert = require("luassert")
local pr = require("nitpick.pr")

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
local ref = { owner = "pwntester", name = "octo.nvim", number = 1601 }

--- The recorded reply in tests/fixtures/<name>.json.
---@param name string
---@return table
local function fixture(name)
  return vim.json.decode(table.concat(vim.fn.readfile(here .. "/fixtures/" .. name .. ".json"), "\n"))
end

--- A reply whose PR has these fields over the open fixture's.
---@param fields table
---@return table
local function reply_with(fields)
  local reply = fixture("pr_open")
  for k, v in pairs(fields) do
    reply.data.repository.pullRequest[k] = v
  end
  return reply
end

--- A commits(last:1) block holding `contexts`.
---@param contexts table[]
local function commits(contexts)
  return { nodes = { { commit = { statusCheckRollup = { contexts = { nodes = contexts } } } } } }
end

describe("pr.parse", function()
  it("reads an open PR: its identity, branches, author, merge state and checks", function()
    local p = pr.parse(fixture("pr_open"), ref)
    assert.equals("PR_kwDOEdDlnM8AAAABRUgShA", p.id)
    assert.equals("fix(label): support label names containing spaces", p.title)
    assert.equals("open", p.state)
    assert.equals("fix/label-names-with-spaces", p.head)
    assert.equals("master", p.base)
    assert.same({ login = "lyn1dev", is_bot = false }, p.author)
    assert.equals(1795452617, p.created_at)
    assert.equals("unstable", p.merge)
    assert.same({ "passed", "passed" }, vim.tbl_map(function(c)
      return c.state
    end, p.checks))
    assert.same(ref, p.ref)
  end)

  it("has no merge state once merged", function()
    local p = pr.parse(fixture("pr_merged"), ref)
    assert.equals("merged", p.state)
    assert.is_nil(p.merge)
  end)

  it("tells a draft from an open PR, and a bot from a person", function()
    local p = pr.parse(reply_with({ isDraft = true, author = { __typename = "Bot", login = "mergify" } }), ref)
    assert.equals("draft", p.state)
    assert.same({ login = "mergify", is_bot = true }, p.author)
  end)

  it("reads a deleted author as ghost", function()
    assert.equals("ghost", pr.parse(reply_with({ author = vim.NIL }), ref).author.login)
  end)

  it("drops the carriage returns GitHub keeps in a body written in the browser", function()
    assert.equals("a\nb", pr.parse(reply_with({ body = "a\r\nb" }), ref).body)
  end)
end)

describe("pr.parse_checks", function()
  it("reads check runs by status and conclusion, and commit statuses by state", function()
    local checks = pr.parse_checks(commits({
      { __typename = "CheckRun", name = "build", status = "IN_PROGRESS", conclusion = vim.NIL, detailsUrl = "u1" },
      { __typename = "CheckRun", name = "lint", status = "COMPLETED", conclusion = "FAILURE", detailsUrl = "u2" },
      { __typename = "CheckRun", name = "docs", status = "COMPLETED", conclusion = "SKIPPED", detailsUrl = vim.NIL },
      { __typename = "CheckRun", name = "late", status = "COMPLETED", conclusion = "TIMED_OUT", detailsUrl = "u3" },
      { __typename = "StatusContext", context = "ci/legacy", state = "PENDING", targetUrl = "u4" },
      { __typename = "StatusContext", context = "ci/old", state = "ERROR", targetUrl = vim.NIL },
    }))
    assert.same({
      { name = "build", state = "running", url = "u1" },
      { name = "lint", state = "failed", url = "u2" },
      { name = "docs", state = "skipped" },
      { name = "late", state = "failed", url = "u3" },
      { name = "ci/legacy", state = "running", url = "u4" },
      { name = "ci/old", state = "failed" },
    }, checks)
  end)

  it("is empty for a commit with no checks", function()
    assert.same({}, pr.parse_checks({ nodes = { { commit = { statusCheckRollup = vim.NIL } } } }))
  end)
end)

describe("pr.epoch", function()
  it("reads GitHub's UTC times, leap days and year ends included", function()
    assert.equals(0, pr.epoch("1970-01-01T00:00:00Z"))
    assert.equals(951868799, pr.epoch("2000-02-29T23:59:59Z"))
    assert.equals(946598400, pr.epoch("1999-12-31T00:00:00Z"))
    assert.equals(1772366400, pr.epoch("2026-03-01T12:00:00Z"))
  end)
end)

describe("pr.update", function()
  local async = require("nitpick.async")
  local sh = async.sh
  after_each(function()
    async.sh = sh
  end)

  --- The gh command pr.update runs for `fields`.
  local function command(fields)
    local cmd
    async.sh = function(c)
      cmd = c
      return { code = 0, stdout = "{}", stderr = "" }
    end
    local ok
    coroutine.wrap(function()
      ok = pr.update("PR_1", fields)
    end)()
    assert.is_true(ok)
    return cmd
  end

  it("sends only the fields given", function()
    local cmd = command({ body = "new body" })
    local query = cmd[vim.fn.index(cmd, "-f") + 2]
    assert.equals("query=mutation($id:ID!,$body:String!){ updatePullRequest(input:{pullRequestId:$id,body:$body}){ pullRequest{ id } } }", query)
    assert.is_true(vim.tbl_contains(cmd, "id=PR_1"))
    assert.is_true(vim.tbl_contains(cmd, "body=new body"))
    assert.is_false(vim.iter(cmd):any(function(a)
      return a:find("^title=") ~= nil
    end))
  end)

  it("sends the title and body together", function()
    local cmd = command({ title = "T", body = "B" })
    assert.is_true(vim.tbl_contains(cmd, "title=T"))
    assert.is_true(vim.tbl_contains(cmd, "body=B"))
  end)
end)

describe("pr.parse_reviewers", function()
  --- A recorded reply's PR by its case name (tests/fixtures/reviewers.json, names changed).
  local function recorded(case)
    local cases = vim.json.decode(table.concat(vim.fn.readfile(here .. "/fixtures/reviewers.json"), "\n"))
    return cases[case].data.repository.pullRequest
  end

  --- A PR node from requests ({ login, code owner }) and reviews ({ login, state }), by `author`.
  local function node(author, requests, reviews)
    return {
      author = { login = author },
      reviewRequests = {
        nodes = vim.tbl_map(function(r)
          return { asCodeOwner = r[2], requestedReviewer = { __typename = "User", login = r[1] } }
        end, requests),
      },
      latestReviews = {
        nodes = vim.tbl_map(function(r)
          return { state = r[2], author = { login = r[1] }, onBehalfOf = { nodes = {} } }
        end, reviews),
      },
    }
  end

  --- Reviewers as "name kind state" strings, code owners starred.
  local function brief(reviewers)
    return vim.tbl_map(function(r)
      return ("%s%s %s %s"):format(r.name, r.code_owner and "*" or "", r.kind, r.state)
    end, reviewers)
  end

  it("lists requested teams and users pending, code owners marked, then unrequested reviews", function()
    local reviewers = pr.parse_reviewers(recorded("teams_and_an_unrequested_review"))
    assert.same({
      "acme/physics* team pending",
      "acme/runtime* team pending",
      "bob user pending",
      "carol user pending",
      "dave user approved",
    }, brief(reviewers))
    assert.same({ "acme/devs", "acme/orchestrator" }, reviewers[5].on_behalf_of)
    assert.same({}, reviewers[1].on_behalf_of)
  end)

  it("lists a team's auto-assigned member as a request of its own", function()
    assert.same({
      "acme/platform* team pending",
      "frank user pending",
      "claude user commented",
    }, brief(pr.parse_reviewers(recorded("team_and_its_auto_assigned_member"))))
  end)

  it("reads each submitted review's state", function()
    assert.same(
      { "a user approved", "b user changes_requested", "c user commented" },
      brief(pr.parse_reviewers(node("me", {}, { { "a", "APPROVED" }, { "b", "CHANGES_REQUESTED" }, { "c", "COMMENTED" } })))
    )
  end)

  it("keeps a reviewer requested again pending, once", function()
    assert.same({ "a user pending" }, brief(pr.parse_reviewers(node("me", { { "a", false } }, { { "a", "APPROVED" } }))))
  end)

  it("leaves out the author's own reviews, drafts and dismissed reviews", function()
    assert.same(
      {},
      brief(pr.parse_reviewers(node("me", {}, { { "me", "COMMENTED" }, { "a", "PENDING" }, { "b", "DISMISSED" } })))
    )
  end)

  it("is part of the parsed PR", function()
    assert.same({}, pr.parse(fixture("pr_open"), ref).reviewers)
  end)
end)
