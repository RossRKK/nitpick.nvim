-- The compose box: a short split under the current window to write a comment in.

local M = {}

--- A scratch window to compose text. Calls on_submit(body, close) on <C-s>.
--- `initial` prefills it (and skips insert mode, e.g. when editing). By default
--- an empty body cancels (closes without submitting); `allow_empty` lets an
--- empty body through instead (the review summary is optional, so <C-s> on an
--- empty compose window still submits).
---
--- Opens as a short split directly below the current window rather than a
--- float: nothing gets covered, and moving between the code and the compose
--- area is ordinary <C-w>j/k — a float needs mouse or <C-w>w gymnastics, and
--- copying context into the comment is a two-window workflow. Splitting the
--- current window (not the top level) keeps the box under the buffer it
--- comments on, and keeps it out of the way of edge-panel managers like edgy.
---@param title string
---@param initial string[]?
---@param on_submit fun(body: string, close: fun())
---@param allow_empty boolean?
local COMPOSE_HEIGHT = 8

--- Run fn with 'splitkeep' forced to "cursor". With splitkeep=screen (set by
--- edge-panel managers such as edgy so the middle windows don't jump when a
--- panel opens) Neovim keeps the TEXT on the same screen rows when a window
--- shrinks or grows, and moves the CURSOR when it would fall off the edge --
--- so opening the compose split under a cursor in the bottom rows drags the
--- cursor up, away from the line being commented on, and it never comes back.
--- "cursor" keeps the cursor line and scrolls the text instead, which is what
--- a box that comments on the cursor line needs.
---@generic T
---@param fn fun(): T
---@return T
local function with_cursor_splitkeep(fn)
  local saved = vim.o.splitkeep
  vim.o.splitkeep = "cursor"
  local ok, res = pcall(fn)
  vim.o.splitkeep = saved
  if not ok then
    error(res, 0)
  end
  return res
end

--- Retitle a compose box. The title is a winbar, a statusline format, so % is escaped.
---@param win integer
---@param title string
function M.set_title(win, title)
  vim.wo[win].winbar = ("%%#Title# %s %%#Comment# · <C-s> send · q cancel "):format(
    (title:gsub("%%", "%%%%"))
  )
end

function M.open_input(title, initial, on_submit, allow_empty)
  local input = vim.api.nvim_create_buf(false, true)
  vim.bo[input].filetype = "markdown"
  -- After the filetype, so it beats any FileType textwidth: GitHub keeps single
  -- newlines in comments, so a hard wrap would reach the PR as line breaks.
  -- The window soft-wraps instead (below).
  vim.bo[input].textwidth = 0
  vim.bo[input].bufhidden = "wipe"
  if initial and #initial > 0 then
    vim.api.nvim_buf_set_lines(input, 0, -1, false, initial)
  end
  local win = with_cursor_splitkeep(function()
    return vim.api.nvim_open_win(input, true, {
      split = "below",
      win = 0,
      height = COMPOSE_HEIGHT,
    })
  end)
  M.set_title(win, title)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      with_cursor_splitkeep(function()
        vim.api.nvim_win_close(win, true)
      end)
    end
  end
  local function submit()
    local body = vim.trim(table.concat(vim.api.nvim_buf_get_lines(input, 0, -1, false), "\n"))
    if body == "" and not allow_empty then
      close()
      return
    end
    on_submit(body, close)
  end
  vim.keymap.set({ "n", "i" }, "<C-s>", submit, { buffer = input, desc = "Send" })
  vim.keymap.set("n", "q", close, { buffer = input, desc = "Cancel" })
  if not (initial and #initial > 0) then
    vim.cmd("startinsert")
  end
  return win, close
end

return M
