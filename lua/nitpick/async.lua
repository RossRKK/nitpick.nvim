-- Coroutine helpers: nitpick's gh and git calls yield instead of blocking the editor.

local M = {}

--- Run a command async, yielding until it exits. Returns the vim.system result
--- object ({ code, stdout, stderr }). MUST run inside a coroutine. `stdin`, when
--- given, is fed to the process's stdin (used to POST a review payload as JSON).
---@param cmd string[]
---@param cwd string?
---@param stdin string?
function M.sh(cmd, cwd, stdin)
  local co = assert(coroutine.running(), "nitpick: must run inside a coroutine")
  vim.system(cmd, { text = true, cwd = cwd, stdin = stdin }, function(obj)
    vim.schedule(function()
      coroutine.resume(co, obj)
    end)
  end)
  return coroutine.yield()
end

--- Drive an async body on a coroutine, surfacing errors as a notification.
---@param fn fun()
function M.run(fn)
  coroutine.wrap(function()
    local ok, err = pcall(fn)
    if not ok then
      vim.notify("nitpick: " .. tostring(err), vim.log.levels.ERROR)
    end
  end)()
end

--- vim.ui.select as a coroutine call. Returns the chosen 1-based index, or nil.
--- Handles both the async pickers (snacks: callback fires later, so
--- we yield and resume) and Neovim's builtin select (callback fires *before*
--- vim.ui.select returns — resuming a still-running coroutine would error, so we
--- just hand back the answer directly).
---@param items string[]
---@param opts table
function M.pick(items, opts)
  local co = coroutine.running()
  local answered, answer = false, nil
  vim.ui.select(items, opts, function(_, idx)
    answered, answer = true, idx
    if coroutine.status(co) == "suspended" then
      coroutine.resume(co, idx)
    end
  end)
  if answered then
    return answer
  end
  return coroutine.yield()
end

return M
