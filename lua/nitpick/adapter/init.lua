-- The active explorer adapter. The single seam between nitpick.nvim's core
-- (nitpick/init.lua) and the file explorer that draws its comment marker.
--
-- To port the marker to a different explorer, write a sibling module in this
-- directory exposing the same interface (marker_component / redraw; see
-- nitpick/adapter/neotree.lua) and re-point this require at it.
return require("nitpick.adapter.neotree")
