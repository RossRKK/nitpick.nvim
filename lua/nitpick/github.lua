-- GitHub through the gh CLI: JSON calls, readable errors, and who's who.

local async = require("nitpick.async")

local M = {}

-- The authenticated GitHub login, cached; used to find your own comments to edit.
local viewer
-- login -> resolved display name, cached in-memory. "" means "resolved, but no
-- display name set" (fall back to @login); nil means "not looked up yet".
M.names = {}

--- Run gh and JSON-decode stdout. Returns (value, nil) or (nil, errmsg).
---@param args string[]
---@param cwd string?
function M.json(args, cwd)
  local obj = async.sh(vim.list_extend({ "gh" }, args), cwd)
  if obj.code ~= 0 then
    return nil, (obj.stderr ~= "" and obj.stderr or "gh exited " .. obj.code)
  end
  local ok, decoded = pcall(vim.json.decode, obj.stdout)
  if not ok then
    return nil, "could not parse gh JSON"
  end
  return decoded
end

--- One line for a GitHub API error body. The `message` alone is useless for a
--- 422 ("Unprocessable Entity"); the reason lives in `errors`, each either a
--- string or an object with its own message/field/code. Those are appended
--- after a colon, joined by "; ".
---@param decoded { message: string, errors: any[]? }
---@return string
function M.api_error_text(decoded)
  local parts = {}
  for _, e in ipairs(type(decoded.errors) == "table" and decoded.errors or {}) do
    if type(e) == "string" then
      parts[#parts + 1] = e
    elseif type(e) == "table" then
      local text = e.message or e.code or vim.inspect(e)
      if e.field then
        text = e.field .. ": " .. text
      end
      parts[#parts + 1] = text
    end
  end
  if #parts == 0 then
    return decoded.message
  end
  return decoded.message .. ": " .. table.concat(parts, "; ")
end

--- A short, single-line summary of a failed gh call, safe to notify without
--- tripping the "Press ENTER to continue" prompt. Prefers the API error's
--- "message" field when the body is JSON; otherwise collapses stderr/stdout to
--- one line and truncates.
---@param obj table vim.system result ({ code, stdout, stderr })
---@return string
function M.error_text(obj)
  for _, s in ipairs({ obj.stderr, obj.stdout }) do
    if s and s ~= "" then
      local ok, decoded = pcall(vim.json.decode, s)
      if ok and type(decoded) == "table" and type(decoded.message) == "string" then
        return M.api_error_text(decoded)
      end
    end
  end
  local msg = (obj.stderr and obj.stderr ~= "" and obj.stderr) or obj.stdout or ""
  msg = vim.trim(msg:gsub("%s+", " "))
  if msg == "" then
    msg = "gh error"
  end
  return (#msg > 200) and (msg:sub(1, 200) .. "…") or msg
end

--- The authenticated GitHub login (cached). Used to find your own comments.
---@param root string
---@return string?
function M.viewer(root)
  if viewer then
    return viewer
  end
  local obj = async.sh({ "gh", "api", "user", "--jq", ".login" }, root)
  if obj.code == 0 then
    viewer = vim.trim(obj.stdout)
  end
  return viewer
end

--- Fill M.names for any of `logins` not yet looked up (one gh call each, but
--- only once per login per session). Runs in a coroutine like the other gh work.
---@param root string
---@param logins table<string, boolean> set of login -> true
function M.resolve_names(root, logins)
  for login in pairs(logins) do
    if M.names[login] == nil then
      -- `.name // ""` yields "" (not null) when the user has no display name.
      local obj = async.sh({ "gh", "api", "users/" .. login, "--jq", '.name // ""' }, root)
      M.names[login] = (obj.code == 0) and vim.trim(obj.stdout) or ""
    end
  end
end

return M
