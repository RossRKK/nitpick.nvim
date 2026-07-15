-- neo-tree adapter for the nitpick UI.
--
-- All of nitpick.nvim's coupling to a specific file explorer lives behind this
-- interface (see nitpick/adapter/init.lua, which selects the active one):
--
--   marker_component(config, node, state) -> chunk   a neo-tree renderer
--     component that draws a speech-bubble marker before a node's name when the
--     path (or, for a directory, a descendant) carries PR comments or drafts.
--   redraw()   repaint the explorer so the component picks up new state.
--
-- To port the marker to another explorer, write a sibling module exposing the
-- same two and re-point nitpick/adapter/init.lua at it.

local M = {}

--- A neo-tree renderer component: a speech bubble when the path has PR comments
--- or drafts (directories light up from any commented descendant). Placed before
--- "name" in the file/directory renderers (see plugins/explorer.lua).
---@return table chunk
function M.marker_component(_, node, _)
  if require("nitpick").has_comments(node.path) then
    -- "\xef\x81\xb5" is U+F075, the nerd-font speech bubble (fa-comment); written
    -- as bytes so the glyph can't be lost in transit when the file is edited.
    return { text = "\xef\x81\xb5 ", highlight = "ReviewCommentTreeIcon" }
  end
  -- neo-tree renders a single chunk; empty text is a no-op.
  return { text = "" }
end

--- Repaint the filesystem explorer so the marker component re-runs. Safe to call
--- when neo-tree isn't loaded or no tree is open.
function M.redraw()
  local ok, manager = pcall(require, "neo-tree.sources.manager")
  if ok then
    pcall(manager.refresh, "filesystem")
  end
end

return M
