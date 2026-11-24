-- The stack a PR is in: ordered from recorded PR nodes (tests/fixtures, names
-- changed), and found on a stand-in GitHub by walking base branches.

local assert = require("luassert")
local stack = require("nitpick.stack")

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")

--- The recorded PR nodes as stack rows.
---@return nitpick.StackPr[]
local function recorded()
  local nodes = vim.json.decode(table.concat(vim.fn.readfile(here .. "/fixtures/stack_nodes.json"), "\n"))
  return vim.tbl_map(stack.parse_node, nodes)
end

--- Rows from { number, head, base } triples.
local function rows(specs)
  return vim.tbl_map(function(s)
    return { number = s[1], title = "PR " .. s[1], head = s[2], base = s[3], draft = false }
  end, specs)
end

---@param s nitpick.Stack?
local function numbers(s)
  return s and vim.tbl_map(function(r)
    return r.number
  end, s.rows)
end

describe("stack.parse_node", function()
  it("reads a PR node's branches, draft state and rolled-up checks", function()
    local by_number = {}
    for _, r in ipairs(recorded()) do
      by_number[r.number] = r
    end
    assert.same({
      number = 8865,
      title = "Add the workers page to the dashboard",
      head = "rkk/workers-ui",
      base = "rkk/git-api-deploy",
      draft = true,
      checks = "running",
    }, by_number[8865])
    assert.equals("passed", by_number[8839].checks)
  end)

  it("reads the review decision", function()
    local r = stack.parse_node({ number = 1, title = "t", headRefName = "a", baseRefName = "main", isDraft = false, reviewDecision = "CHANGES_REQUESTED" })
    assert.equals("changes_requested", r.review)
    assert.is_nil(r.checks)
  end)
end)

describe("stack.order", function()
  it("orders a recorded stack top first, down to the trunk, marking the PR it was found from", function()
    local s = assert(stack.order(recorded(), 8909))
    assert.same({ 8865, 8909, 8839 }, numbers(s))
    assert.equals(2, s.current)
    assert.equals("master", s.trunk)
  end)

  it("finds the same stack from any PR in it", function()
    for _, number in ipairs({ 8839, 8909, 8865 }) do
      assert.same({ 8865, 8909, 8839 }, numbers(stack.order(recorded(), number)))
    end
  end)

  it("is a stack of one over its trunk for a PR stacked with nothing", function()
    local s = assert(stack.order(recorded(), 9135))
    assert.same({ 9135 }, numbers(s))
    assert.equals(1, s.current)
    assert.equals("master", s.trunk)
  end)

  it("is nil for a PR not among them", function()
    assert.is_nil(stack.order(recorded(), 1))
  end)

  it("keeps a fork's branches together, newest above, each over its base", function()
    local s = stack.order(rows({ { 1, "a", "main" }, { 2, "b", "a" }, { 3, "c", "a" }, { 4, "d", "b" } }), 3)
    assert.same({ 3, 4, 2, 1 }, numbers(s))
  end)

  it("stops at a base cycle rather than looping", function()
    local found = numbers(stack.order(rows({ { 1, "a", "b" }, { 2, "b", "a" } }), 1))
    table.sort(found)
    assert.same({ 1, 2 }, found)
  end)
end)

describe("stack.row_of", function()
  it("rolls a PR's checks up: any failed, else any running, else passed", function()
    local function rolled(states)
      return stack.row_of({
        ref = { number = 1 },
        title = "t",
        head = "a",
        base = "main",
        state = "open",
        checks = vim.tbl_map(function(s)
          return { name = s, state = s }
        end, states),
      }).checks
    end
    assert.equals("failed", rolled({ "passed", "failed", "running" }))
    assert.equals("running", rolled({ "passed", "running" }))
    assert.equals("passed", rolled({ "passed", "skipped" }))
    assert.is_nil(rolled({ "skipped" }))
    assert.is_nil(rolled({}))
  end)
end)

describe("stack.fetch", function()
  local github = require("nitpick.github")
  local json = github.json
  after_each(function()
    github.json = json
  end)

  --- Serve the recorded nodes as GitHub would answer the walk's queries, counting them.
  local function serve()
    local nodes = vim.json.decode(table.concat(vim.fn.readfile(here .. "/fixtures/stack_nodes.json"), "\n"))
    local asked = 0
    github.json = function(args)
      asked = asked + 1
      local repository = {}
      for i, a in ipairs(args) do
        local var, by, branch = a:match("^((%a+)%d+)=(.*)$")
        if args[i - 1] == "-f" and var then
          repository[var] = {
            nodes = vim.tbl_filter(function(n)
              return n[by .. "RefName"] == branch
            end, nodes),
          }
        end
      end
      return { data = { repository = repository } }
    end
    return function()
      return asked
    end
  end

  it("walks down to the trunk and back up, finding the whole stack from its middle", function()
    local queries = serve()
    local current = vim.tbl_filter(function(r)
      return r.number == 8909
    end, recorded())[1]
    local s
    coroutine.wrap(function()
      s = stack.fetch({ owner = "acme", name = "mono", number = 8909 }, current)
    end)()
    assert.same({ 8865, 8909, 8839 }, numbers(s))
    assert.equals("master", s.trunk)
    assert.is_true(queries() <= 3, "a query per level, both ways at once: " .. queries())
  end)

  it("leaves a PR with nothing stacked on it a stack of one", function()
    serve()
    local current = vim.tbl_filter(function(r)
      return r.number == 9135
    end, recorded())[1]
    local s
    coroutine.wrap(function()
      s = stack.fetch({ owner = "acme", name = "mono", number = 9135 }, current)
    end)()
    assert.same({ 9135 }, numbers(s))
  end)

  it("is nil when GitHub can't be asked", function()
    github.json = function()
      return nil, "offline"
    end
    local s = "unset"
    coroutine.wrap(function()
      s = stack.fetch({ owner = "o", name = "r", number = 1 }, rows({ { 1, "a", "main" } })[1])
    end)()
    assert.is_nil(s)
  end)
end)
