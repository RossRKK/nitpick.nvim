-- Branch resolution: which name nitpick hands to `gh pr list --head`. Under jj
-- HEAD is detached, so the nearest bookmark at or below @ is the answer.

local assert = require("luassert")
local nitpick = require("nitpick")

--- Run `fn` inside a coroutine and pump the event loop until it returns.
local function run(fn)
  local result, done
  coroutine.wrap(function()
    result = fn()
    done = true
  end)()
  assert.is_true(vim.wait(10000, function() return done end), "timed out")
  return result
end

local function sh(cmd, cwd)
  local obj = vim.system(cmd, { cwd = cwd, text = true }):wait()
  assert.equals(0, obj.code, table.concat(cmd, " ") .. "\n" .. (obj.stderr or ""))
end

describe("first_bookmark", function()
  it("returns the first non-empty line", function()
    assert.equals("feat/x", nitpick.first_bookmark("\n feat/x \nmain\n"))
  end)
  it("is empty for empty output", function()
    assert.equals("", nitpick.first_bookmark(""))
    assert.equals("", nitpick.first_bookmark(nil))
  end)
end)

describe("current_branch", function()
  local root
  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    sh({ "git", "init", "-q", "-b", "main" }, root)
    sh({ "git", "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init" }, root)
  end)
  after_each(function()
    vim.fn.delete(root, "rf")
  end)

  it("uses the checked-out git branch in a plain git repo", function()
    sh({ "git", "checkout", "-q", "-b", "feat/git" }, root)
    assert.equals("feat/git", run(function() return nitpick.current_branch(root) end))
  end)

  it("uses the bookmark below an empty @ in a colocated jj repo", function()
    local env = { JJ_USER = "t", JJ_EMAIL = "t@t", JJ_CONFIG = "/dev/null" }
    local function jj(args)
      local obj = vim.system(vim.list_extend({ "jj" }, args), { cwd = root, text = true, env = env }):wait()
      assert.equals(0, obj.code, table.concat(args, " ") .. "\n" .. (obj.stderr or ""))
    end
    jj({ "git", "init", "--colocate" })
    jj({ "bookmark", "create", "feat/jj", "-r", "@-" })
    -- HEAD is detached now; the working copy @ is empty and has no bookmark.
    assert.equals("feat/jj", run(function() return nitpick.current_branch(root) end))
  end)

  it("is empty when nothing names the checkout", function()
    sh({ "git", "checkout", "-q", "--detach" }, root)
    assert.equals("", run(function() return nitpick.current_branch(root) end))
  end)
end)

describe("repo_root", function()
  local root
  local env = { JJ_USER = "t", JJ_EMAIL = "t@t", JJ_CONFIG = "/dev/null" }
  local function jj(cwd, args)
    local obj = vim.system(vim.list_extend({ "jj" }, args), { cwd = cwd, text = true, env = env }):wait()
    assert.equals(0, obj.code, table.concat(args, " ") .. "\n" .. (obj.stderr or ""))
  end
  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    vim.system({ "git", "init", "-q", "-b", "main" }, { cwd = root }):wait()
    jj(root, { "git", "init", "--colocate" })
  end)
  after_each(function()
    vim.fn.delete(root, "rf")
  end)

  -- A secondary workspace lives under the main one here, like ionics/.worktrees,
  -- and has a .jj but no .git. It must be its own root, not the main checkout.
  it("stops at a secondary jj workspace nested inside the main one", function()
    local ws = root .. "/.worktrees/feat"
    vim.fn.mkdir(root .. "/.worktrees", "p")
    jj(root, { "workspace", "add", ws })
    vim.fn.mkdir(ws .. "/src", "p")
    vim.fn.writefile({ "" }, ws .. "/src/a.lua")

    assert.equals(vim.fs.normalize(ws), nitpick.repo_root(ws .. "/src/a.lua"))
    assert.equals(vim.fs.normalize(root), nitpick.repo_root(root .. "/README"))
  end)

  it("resolves the branch of the secondary workspace, not the main one", function()
    local ws = root .. "/.worktrees/feat"
    jj(root, { "commit", "-m", "base" })
    jj(root, { "bookmark", "create", "main-side", "-r", "@-" })
    vim.fn.mkdir(root .. "/.worktrees", "p")
    jj(root, { "workspace", "add", ws })
    jj(ws, { "bookmark", "create", "feat/ws", "-r", "@-" })

    assert.equals("feat/ws", run(function() return nitpick.current_branch(nitpick.repo_root(ws)) end))
  end)
end)
