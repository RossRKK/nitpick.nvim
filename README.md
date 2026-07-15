# nitpick.nvim

Inline GitHub PR review comments inside Neovim. Leave line comments and drafts on
the buffer as you read, see which files carry comments via a [neo-tree][] marker,
and submit the batch as a PR review. Comment positions survive local edits (they
remap across the diff), and comment-to-comment navigation moves you through the
thread.

Pairs with [triage.nvim][] (per-file review status), but stands alone.

## Install

[lazy.nvim][]:

```lua
{
  "RossRKK/nitpick.nvim",
  dependencies = { "nvim-neo-tree/neo-tree.nvim" },
  config = function()
    require("nitpick").setup({})
  end,
}
```

## Setup

`require("nitpick").setup(opts)` accepts:

| Key       | Type       | Description                                                        |
| --------- | ---------- | ----------------------------------------------------------------- |
| `verdict` | `fun()`    | Called to resolve the review verdict on submit. Wire triage's `verdict` here. |

The neo-tree "has comments" marker is registered as the `nitpick_marker`
component (`require("nitpick.adapter").marker_component`); add it to your
neo-tree filesystem renderers. See the source for the full command/keymap
surface.

## Tests

```bash
make test
```

Headless plenary/busted; covers the tree-decorator set (which paths light up once
comments and drafts are folded together), the line remap across edits, and
comment navigation.

[neo-tree]: https://github.com/nvim-neo-tree/neo-tree.nvim
[triage.nvim]: https://github.com/RossRKK/triage.nvim
[lazy.nvim]: https://github.com/folke/lazy.nvim
