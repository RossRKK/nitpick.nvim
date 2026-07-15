# nitpick.nvim

Inline GitHub PR review comments inside Neovim. Leave line comments and drafts on
the buffer as you read, see which files carry comments via a [neo-tree][] marker,
and submit the batch as a PR review. Comment positions survive local edits (they
remap across the diff), and comment-to-comment navigation moves you through the
thread.

Pairs with [triage.nvim][] (per-file review status), but stands alone.

## Requirements

- Neovim 0.10+
- [neo-tree.nvim][] — the "has comments" file marker
- **[GitHub CLI (`gh`)][gh]**, authenticated (`gh auth login`) — nitpick shells
  out to `gh` to read a PR's comments and submit the review. Without it on your
  `PATH` the GitHub-backed commands are inert.

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

## Wiring with triage.nvim

The two are designed to run as one review mode: a single toggle shows/hides
both, and nitpick submits under triage's verdict. Wire them in one lazy spec —
triage's `on_toggle` reveals nitpick, and nitpick's `verdict` borrows triage's:

```lua
{
  {
    "RossRKK/triage.nvim",
    dependencies = { "nvim-neo-tree/neo-tree.nvim", "lewis6991/gitsigns.nvim" },
    config = function()
      require("triage").setup({
        -- Toggling review mode reveals/hides nitpick's comments too.
        on_toggle = function(on)
          require("nitpick").set_shown(on)
        end,
      })
    end,
  },
  {
    "RossRKK/nitpick.nvim",
    dependencies = { "RossRKK/triage.nvim", "nvim-neo-tree/neo-tree.nvim" },
    config = function()
      -- nitpick submits its batch under triage's rolled-up verdict.
      require("nitpick").setup({ verdict = require("triage").verdict })
    end,
  },
}
```

Standalone (no triage), `setup({})` is enough — comments and drafts work on their
own; only the shared toggle and verdict come from triage.

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
[gh]: https://cli.github.com/
