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
| `verdict` | `fun()`    | Called to infer the review verdict on submit. Wire triage's `verdict` here. `<C-e>` in the submit box overrides it. |

The neo-tree "has comments" marker is registered as the `nitpick_marker`
component (`require("nitpick.adapter").marker_component`); add it to your
neo-tree filesystem renderers. See the source for the full command/keymap
surface.

## Wiring with triage.nvim

The two are designed to run as one review mode: a single toggle shows/hides
both (nitpick shows your drafts; other people's PR comments are opt-in with
`<leader>rh`), and nitpick submits under triage's verdict. Wire them in one
lazy spec — triage's `on_toggle` reveals nitpick, and nitpick's `verdict`
borrows triage's:

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

## PR buffer

`:NitpickPr [number]` opens a PR (default: the current branch's) as a buffer
named `nitpick://pr/<owner>/<repo>/<number>`. It opens on the stack the PR is
in: open PRs chained through their base branches, top first, over the branch
the bottom one merges into (a PR on its own is a stack of one), each row its
number, title, review decision and checks. The PR's own row holds its title,
edited in place like the description below the rule; `:w` or `<C-s>` saves
them, and refuses if GitHub's copy of an edited field changed since the buffer
loaded. `<CR>` on another row opens that PR (`setup({ on_stack_select })`
replaces this), `gx` opens it in the browser. Under the stack, the header shows
the state, author, reviewers (as GitHub's Reviewers panel lists them, code
owners shielded), merge state and checks, each failed or running check on its
own row: `gd` there opens it.

Under the description, the conversation: comments on the PR, reviews' summaries
and threads on the code (file and line, then the end of the diff hunk), the
newest activity first; GitHub's resolved threads collapse to their file and line,
and threads only bots wrote are hidden (`setup({ show_bots = { "login" } })`
keeps a bot's). Your own comments edit in place like the description, saved by
the same `:w`. `<leader>ra` on a thread replies (in the thread for one on the
code, else as a comment on the PR to its author), `<leader>rc` comments on the
PR, both in the compose box.

## Tests

```bash
nix develop -c make test   # or: nix flake check
```

Headless plenary/busted, with nvim, plenary, git and jj from the flake; covers the tree-decorator set (which paths light up once
comments and drafts are folded together), the line remap across edits,
comment navigation, and the PR buffer: GitHub's reply read from recorded
fixtures (`tests/fixtures`), its header, and saving through a stand-in client.

[neo-tree]: https://github.com/nvim-neo-tree/neo-tree.nvim
[triage.nvim]: https://github.com/RossRKK/triage.nvim
[lazy.nvim]: https://github.com/folke/lazy.nvim
[gh]: https://cli.github.com/
