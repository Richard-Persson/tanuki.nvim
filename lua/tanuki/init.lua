local M = {}

local defaults = {
  remote = "origin",
  hosts = {},
  limit = 50,
  system_notes = true,
  -- stylua: ignore
  keys = {
    select  = { "<cr>", "gl_actions", desc = "Select Action" },
    edit    = { "i"   , "gl_edit"   , desc = "Edit" },
    comment = { "a"   , "gl_comment", desc = "Add Comment" },
    close   = { "c"   , "gl_close"  , desc = "Close" },
    reopen  = { "o"   , "gl_reopen" , desc = "Reopen" },
    browse  = { "gx"  , "gl_browse" , desc = "Open in browser" },
    refresh = { "R"   , "gl_refresh", desc = "Refresh" },
  },
  wo = {
    breakindent = true,
    wrap = true,
    showbreak = "",
    linebreak = true,
    number = false,
    relativenumber = false,
    foldexpr = "v:lua.vim.treesitter.foldexpr()",
    foldmethod = "expr",
    concealcursor = "n",
    conceallevel = 2,
    list = false,
  },
  bo = {},
  scratch = {
    height = 15,
  },
  -- stylua: ignore
  icons = {
    logo      = " ",
    user      = " ",
    checkmark = " ",
    crossmark = " ",
    file      = " ",
    thread    = " ",
    resolved  = " ",
    issue = {
      open   = " ",
      closed = " ",
      other  = " ",
    },
    mr = {
      open   = " ",
      closed = " ",
      merged = " ",
      draft  = " ",
      other  = " ",
    },
    pipeline = {
      success  = " ",
      failed   = " ",
      running  = " ",
      pending  = " ",
      canceled = " ",
      skipped  = " ",
      manual   = " ",
      other    = " ",
    },
    emoji = {
      thumbsup   = "👍",
      thumbsdown = "👎",
      laughing   = "😆",
      smile      = "😄",
      tada       = "🎉",
      confused   = "😕",
      heart      = "❤️",
      rocket     = "🚀",
      eyes       = "👀",
    },
  },
}

M._config = nil
local did_hl = false
local did_setup = false

local function set_hl()
  did_hl = true
  Snacks.util.set_hl({
    Normal = "NormalFloat",
    Title = "FloatTitle",
    ScratchTitle = "Number",
    ScratchBorder = "Number",
    Green = { fg = "#2da160" },
    Purple = { fg = "#7b58cf" },
    Gray = { fg = "#737278" },
    Red = { fg = "#dd2b0e" },
    Orange = { fg = "#e9be74" },
    Blue = { fg = "#428fdc" },
    Branch = "@markup.link",
    IssueOpen = "TanukiGreen",
    IssueClosed = "TanukiBlue",
    IssueOther = "TanukiGray",
    MrOpen = "TanukiGreen",
    MrClosed = "TanukiRed",
    MrMerged = "TanukiBlue",
    MrDraft = "TanukiGray",
    MrOther = "TanukiGray",
    PipelineSuccess = "TanukiGreen",
    PipelineFailed = "TanukiRed",
    PipelineRunning = "TanukiBlue",
    PipelinePending = "TanukiOrange",
    PipelineCanceled = "TanukiGray",
    PipelineSkipped = "TanukiGray",
    PipelineManual = "TanukiGray",
    PipelineOther = "TanukiGray",
    Label = "@property",
    Delim = "@punctuation.delimiter",
    UserBadge = "DiagnosticInfo",
    AuthorBadge = "DiagnosticWarn",
    ReactionBadge = "Special",
    StatBadge = "Special",
    FileBadge = "Directory",
    ResolvedBadge = "TanukiGreen",
    UnresolvedBadge = "DiagnosticWarn",
    SystemNote = "Comment",
    MergeOk = "DiagnosticInfo",
    MergeBlocked = "DiagnosticError",
  }, { default = true, prefix = "Tanuki" })
end

function M.config()
  if not did_hl and not vim.in_fast_event() then
    set_hl()
  end
  M._config = M._config or vim.deepcopy(defaults)
  return M._config
end

function M.setup(opts)
  M._config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  M.init()
end

function M.init()
  if did_setup then
    return
  end
  did_setup = true
  pcall(vim.api.nvim_del_augroup_by_name, "tanuki.init")
  require("tanuki.buf").setup()
end

local subcommands = {
  issues = function(args)
    M.issues(args)
  end,
  mrs = function(args)
    M.mrs(args)
  end,
  mr = function()
    M.current_mr()
  end,
  actions = function()
    M.actions()
  end,
}

function M.command(fargs)
  local sub = fargs[1] or "issues"
  if not subcommands[sub] then
    return Snacks.notify.error("Unknown `:GitLab` subcommand `" .. sub .. "`", { title = "GitLab" })
  end
  local args = {}
  for i = 2, #fargs do
    local k, v = fargs[i]:match("^([%w_]+)=(.*)$")
    if k then
      args[k] = tonumber(v) or v == "true" or (v ~= "false" and v)
    end
  end
  subcommands[sub](args)
end

function M.complete(line)
  if #vim.split(line, "%s+") <= 2 then
    return vim.tbl_keys(subcommands)
  end
  return {
    "state=all",
    "state=closed",
    "state=merged",
    "scope=created_by_me",
    "scope=assigned_to_me",
    "author=",
    "assignee=",
    "reviewer=",
    "label=",
    "draft=true",
    "draft=false",
    "project=",
  }
end

function M.issues(opts)
  return require("tanuki.picker").pick("gl_issue", opts)
end

function M.mrs(opts)
  return require("tanuki.picker").pick("gl_mr", opts)
end

function M.actions(opts)
  return require("tanuki.picker").pick("gl_actions", opts)
end

function M.current_mr()
  local Api = require("tanuki.api")
  local ctx = Api.context()
  if not ctx then
    return
  end
  local branch = vim.trim(vim.fn.system({ "git", "branch", "--show-current" }))
  require("snacks.picker.util.async").new(function()
    local mr = Api.current_mr(ctx, branch)
    vim.schedule(function()
      if not mr then
        return Snacks.notify.warn("No open merge request found for branch `" .. branch .. "`")
      end
      vim.cmd.edit(vim.fn.fnameescape(mr.uri))
    end)
  end)
end

return M
