-- The compose box (open_input) splits the current window from below. It must
-- not move the cursor in the code window: with splitkeep=screen Neovim moves a
-- cursor that would fall off the shrunken window's bottom edge, and nothing
-- would bring it back to the line being commented on.

local assert = require("luassert")
local nitpick = require("nitpick")

describe("open_input", function()
  local saved_splitkeep, saved_scrolloff

  before_each(function()
    saved_splitkeep, saved_scrolloff = vim.o.splitkeep, vim.o.scrolloff
    -- Reproduce the user's environment: edgy sets screen, options.lua sets 8.
    vim.o.splitkeep = "screen"
    vim.o.scrolloff = 8
    vim.cmd("only!")
    vim.cmd("enew!")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.fn["repeat"]({ "line" }, 200))
  end)

  after_each(function()
    vim.o.splitkeep, vim.o.scrolloff = saved_splitkeep, saved_scrolloff
    vim.cmd("only!")
  end)

  it("keeps the cursor line when the split opens and when it closes", function()
    local code_win = vim.api.nvim_get_current_win()
    -- Put the cursor in the bottom rows of the window so the shrink would
    -- push it off the edge.
    local height = vim.api.nvim_win_get_height(code_win)
    vim.fn.winrestview({ topline = 100 })
    local target = 100 + height - 1
    vim.api.nvim_win_set_cursor(code_win, { target, 0 })
    assert.equal(target, vim.api.nvim_win_get_cursor(code_win)[1])

    local _, close = nitpick.open_input("t", nil, function() end)
    vim.cmd("stopinsert")
    assert.equal(target, vim.api.nvim_win_get_cursor(code_win)[1])
    -- Jump back to the code window mid-compose: entering a window is when
    -- Neovim pulls a cursor that fell off the bottom edge back into view.
    vim.cmd("wincmd k")
    assert.equal(code_win, vim.api.nvim_get_current_win())
    assert.equal(target, vim.api.nvim_win_get_cursor(code_win)[1])

    close()
    assert.equal(target, vim.api.nvim_win_get_cursor(code_win)[1])
    assert.equal("screen", vim.o.splitkeep) -- restored, not leaked
  end)

  it("doesn't hard-wrap the comment as you type", function()
    -- GitHub keeps single newlines in comments, so a hard wrap would reach the
    -- PR as 80-column line breaks. Reproduce a config that gives every markdown
    -- buffer a textwidth, as the user's prose autocmd does.
    local group = vim.api.nvim_create_augroup("nitpick_test_prose", { clear = true })
    vim.api.nvim_create_autocmd("FileType", {
      group = group,
      pattern = "markdown",
      callback = function()
        vim.opt_local.textwidth = 80
        vim.opt_local.formatoptions:append("t")
      end,
    })

    local win, close = nitpick.open_input("t", nil, function() end)
    vim.cmd("stopinsert")
    local buf = vim.api.nvim_win_get_buf(win)
    assert.equal("markdown", vim.bo[buf].filetype)
    assert.equal(0, vim.bo[buf].textwidth)

    local long = vim.fn["repeat"]("word ", 40)
    vim.cmd("normal! A" .. long)
    assert.same({ long }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))

    close()
    vim.api.nvim_del_augroup_by_id(group)
  end)
end)
