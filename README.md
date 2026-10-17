# tanuki.nvim

GitLab issues and merge requests in Neovim, on top of the snacks.nvim picker.
Basically [snacks.gh](https://github.com/folke/snacks.nvim/blob/main/docs/gh.md) but for GitLab.

## Requirements

- Neovim >= 0.10
- [snacks.nvim](https://github.com/folke/snacks.nvim)
- [glab](https://gitlab.com/gitlab-org/cli), logged in with `glab auth login` (add `--hostname` for self-hosted GitLab)

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "Richard-Persson/tanuki.nvim",
  dependencies = { "folke/snacks.nvim" },
  cmd = "GitLab",
  opts = {},
  keys = {
    { "<leader>gi", function() require("tanuki").issues() end, desc = "GitLab Issues" },
    { "<leader>gm", function() require("tanuki").mrs() end, desc = "GitLab MRs" },
  },
}
```

## Usage

```vim
:GitLab issues
:GitLab issues state=all author=@me
:GitLab mrs reviewer=@me
:GitLab mr        " MR for the current branch
:GitLab actions   " actions for the MR on the current branch
```

Same options from lua: `require("tanuki").mrs({ state = "merged", label = "bug" })`.

Filters: `state` (open/closed/merged/all), `author`, `assignee`, `reviewer`, `label`,
`milestone`, `scope`, `draft`, `target_branch`, `source_branch`, `limit`.
Use `host` and `project` to point at a project other than the current repo.

`<cr>` on an issue/MR shows the available actions: comment, reply, resolve threads, edit,
close/reopen, labels, reactions, approve, merge, rebase, draft/ready, checkout, diff.

In buffers: `a` comment, `i` edit, `c` close, `o` reopen, `gx` browser, `R` refresh.
In the MR diff, `a` on a line adds a comment. Visual select first to make it a suggestion.
`<c-s>` submits.

## Config

Defaults are in `lua/tanuki/init.lua`. If your remote uses an ssh alias:

```lua
opts = { hosts = { ["gitlab-ssh"] = "gitlab.example.com" } }
```
