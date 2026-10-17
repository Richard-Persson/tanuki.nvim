local Markdown = require("snacks.picker.util.markdown")

local M = {}
local H = Snacks.picker.highlight
local U = Snacks.picker.util

local function time_prop(field)
  return {
    name = U.title(field),
    hl = function(item)
      if item[field] then
        return { { U.reltime(item[field]), "SnacksPickerGitDate" } }
      end
    end,
  }
end

local function users(users)
  local ret = {}
  for _, u in ipairs(users or {}) do
    H.extend(ret, H.badge(u.username, "Identifier"))
    ret[#ret + 1] = { " " }
  end
  return ret
end

function M.emoji(opts, name)
  return opts.icons.emoji[name] or (":" .. name .. ":")
end

M.props = {
  {
    name = "Status",
    hl = function(item, opts)
      local icons = opts.icons[item.type]
      local status = icons[item.status] and item.status or "other"
      local hl = "Tanuki" .. U.title(item.type) .. U.title(status)
      local ret = {}
      H.extend(ret, H.badge(icons[status] .. U.title(item.status), { bg = Snacks.util.color(hl), fg = "#ffffff" }))
      local d = item.data
      if d.target_branch and d.source_branch then
        vim.list_extend(ret, {
          { " " },
          { d.target_branch, "TanukiBranch" },
          { " ← ", "TanukiDelim" },
          { d.source_branch, "TanukiBranch" },
        })
      end
      return ret
    end,
  },
  {
    name = "Project",
    hl = function(item, opts)
      return { { opts.icons.logo, "Special" }, { item.project, "@markup.link" } }
    end,
  },
  {
    name = "Author",
    hl = function(item, opts)
      if item.author then
        return H.badge(opts.icons.user .. " " .. item.author, "TanukiUserBadge")
      end
    end,
  },
  time_prop("created"),
  time_prop("updated"),
  time_prop("closed"),
  time_prop("merged"),
  {
    name = "Reactions",
    hl = function(item, opts)
      local ret = {}
      for _, r in ipairs(item:reactions()) do
        H.extend(ret, H.badge(M.emoji(opts, r.name) .. " " .. r.count, "TanukiReactionBadge"))
        ret[#ret + 1] = { " " }
      end
      return ret
    end,
  },
  {
    name = "Labels",
    hl = function(item)
      local ret = {}
      for _, label in ipairs(item.labels) do
        H.extend(ret, H.badge(label.name, label.color))
        ret[#ret + 1] = { " " }
      end
      return ret
    end,
  },
  {
    name = "Assignees",
    hl = function(item)
      return users(item.data.assignees)
    end,
  },
  {
    name = "Reviewers",
    hl = function(item)
      return users(item.data.reviewers)
    end,
  },
  {
    name = "Milestone",
    hl = function(item)
      if item.data.milestone then
        return H.badge(item.data.milestone.title, "Title")
      end
    end,
  },
  {
    name = "Pipeline",
    hl = function(item, opts)
      local pipeline = item.data.head_pipeline or item.data.pipeline
      if item.type ~= "mr" or not pipeline then
        return
      end
      local status = pipeline.status or "other"
      status = opts.icons.pipeline[status] and status or "other"
      return {
        { opts.icons.pipeline[status] .. U.title(pipeline.status or "unknown"), "TanukiPipeline" .. U.title(status) },
        { " " },
        { "#" .. tostring(pipeline.id), "SnacksPickerDimmed" },
      }
    end,
  },
  {
    name = "Approvals",
    hl = function(item, opts)
      local a = item.approvals
      if item.type ~= "mr" or not a then
        return
      end
      local ret = {}
      local approved = {}
      for _, by in ipairs(a.approved_by or {}) do
        approved[#approved + 1] = by.user
      end
      if a.approvals_required and a.approvals_required > 0 then
        local ok = (a.approvals_left or 0) == 0
        ret[#ret + 1] = {
          ("%s%d/%d"):format(ok and opts.icons.checkmark or "", #approved, a.approvals_required),
          ok and "TanukiMergeOk" or "TanukiUnresolvedBadge",
        }
        ret[#ret + 1] = { " " }
      elseif #approved > 0 then
        ret[#ret + 1] = { opts.icons.checkmark, "TanukiMergeOk" }
      end
      H.extend(ret, users(approved))
      return ret
    end,
  },
  {
    name = "Merge Status",
    hl = function(item, opts)
      local status = item.data.detailed_merge_status
      if item.type ~= "mr" or item.state ~= "open" or not status then
        return
      end
      local ok = status == "mergeable"
      return {
        { (ok and opts.icons.checkmark or opts.icons.crossmark) .. status:gsub("_", " "), ok and "TanukiMergeOk" or "TanukiMergeBlocked" },
      }
    end,
  },
  {
    name = "Threads",
    hl = function(item, opts)
      if item.type ~= "mr" or not item.discussions then
        return
      end
      local total, resolved = 0, 0
      for _, d in ipairs(item.discussions) do
        local first = d.notes and d.notes[1]
        if first and first.resolvable then
          total = total + 1
          resolved = resolved + (first.resolved and 1 or 0)
        end
      end
      if total > 0 then
        return {
          {
            ("%s%d/%d resolved"):format(opts.icons.resolved, resolved, total),
            resolved == total and "TanukiResolvedBadge" or "TanukiUnresolvedBadge",
          },
        }
      end
    end,
  },
  {
    name = "Changes",
    hl = function(item, opts)
      if item.type == "mr" and item.data.changes_count then
        return H.badge(opts.icons.file .. item.data.changes_count, "TanukiStatBadge")
      end
    end,
  },
}

local ns = vim.api.nvim_create_namespace("tanuki.render")

function M.render(buf, item, opts)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local ctx = { item = item, opts = opts }

  local lines = {}

  item.msg = item.title
  lines[#lines + 1] = Snacks.picker.format.commit_message(item, {})
  vim.list_extend(lines[#lines], { { " " }, { item.hash, "SnacksPickerDimmed" } })
  lines[#lines + 1] = {}

  for _, prop in ipairs(M.props) do
    local value = prop.hl(item, opts)
    if value and #value > 0 then
      local line = { { prop.name, "TanukiLabel" }, { ":", "TanukiDelim" }, { " " } }
      H.extend(line, value)
      lines[#lines + 1] = line
    end
  end

  lines[#lines + 1] = {}
  lines[#lines + 1] = { { "---", "@punctuation.special.markdown" } }
  lines[#lines + 1] = {}

  do
    local text = item.body:gsub("<%!%-%-.-%-%->%s*", "")
    local body = vim.split(text, "\n")
    while #body > 0 and body[1]:match("^%s*$") do
      table.remove(body, 1)
    end
    if #body == 0 and not opts.partial then
      body = { "_No description provided._" }
    end
    for _, l in ipairs(body) do
      lines[#lines + 1] = { { l } }
    end
  end

  local discussions = item.discussions or {}
  if #discussions > 0 then
    lines[#lines + 1] = {}
    lines[#lines + 1] = { { "---", "@punctuation.special.markdown" } }
    lines[#lines + 1] = {}
    for _, discussion in ipairs(discussions) do
      local thread = M.discussion(discussion, ctx)
      if #thread > 0 then
        vim.list_extend(lines, thread)
        lines[#lines + 1] = {}
      end
    end
  end

  if H.render(buf, ns, lines) then
    Markdown.render(buf, { bullets = false })
  end

  vim.schedule(function()
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      vim.api.nvim_win_call(win, function()
        if vim.wo.foldmethod == "expr" then
          vim.wo.foldmethod = "expr"
        end
      end)
    end
  end)
end

function M.note_header(note, ctx, first)
  local ret = {}
  local username = note.author and note.author.username or "ghost"
  local is_bot = note.author and note.author.bot or username:find("bot$") ~= nil
  H.extend(
    ret,
    H.badge(
      ("%s %s"):format(is_bot and ctx.opts.icons.logo or ctx.opts.icons.user, username),
      "TanukiUserBadge"
    )
  )
  ret[#ret + 1] = { " " }
  ret[#ret + 1] = { U.reltime(require("tanuki.item").ts(note.created_at) or os.time()), "SnacksPickerGitDate" }
  if username == ctx.item.author then
    ret[#ret + 1] = { " " }
    H.extend(ret, H.badge("Author", "TanukiAuthorBadge"))
  end
  if first and note.position then
    local p = note.position
    local path = p.new_path or p.old_path
    local line = p.new_line or p.old_line
    ret[#ret + 1] = { " " }
    H.extend(ret, H.badge(ctx.opts.icons.file .. path .. (line and (":" .. line) or ""), "TanukiFileBadge"))
  end
  if first and note.resolvable then
    ret[#ret + 1] = { " " }
    if note.resolved then
      H.extend(ret, H.badge(ctx.opts.icons.resolved .. "Resolved", "TanukiResolvedBadge"))
    else
      H.extend(ret, H.badge(ctx.opts.icons.thread .. "Unresolved", "TanukiUnresolvedBadge"))
    end
  end
  return ret
end

function M.note_body(note, ctx)
  local body = (note.body or ""):gsub("\r\n", "\n")
  if body:match("^%s*$") then
    return {}
  end
  local ret = {}
  local md = {}
  for _, line in ipairs(vim.split(body, "\n", { plain = true })) do
    if line:find("^```suggestion") then
      local path = note.position and (note.position.new_path or note.position.old_path)
      line = "```" .. (path and vim.filetype.match({ filename = path }) or "")
      ret[#ret + 1] = H.badge("Suggested change", "TanukiStatBadge")
      md[#md + 1] = ""
    end
    md[#md + 1] = line
    ret[#ret + 1] = { { line } }
  end
  if ctx.markdown == false then
    local extmarks = H.get_highlights({ code = table.concat(md, "\n"), ft = "markdown" })
    for l, line in pairs(extmarks) do
      vim.list_extend(ret[l] or {}, line)
    end
  end
  return ret
end

function M.indent(lines, ctx)
  local indent = {
    { "   ", "Normal" },
    {
      col = 0,
      virt_text = {
        { " ", "Normal" },
        { "┃", { "Normal", "@punctuation.definition.blockquote.markdown" } },
        { " ", "Normal" },
      },
      virt_text_pos = "overlay",
      hl_mode = "combine",
      virt_text_repeat_linebreak = true,
    },
  }

  local first = ctx.markdown == false and {} or {
    { col = 0, end_col = 3, conceal = "", priority = 1000 },
    { " * ", "Normal" },
  }

  local ret = {}
  for l, line in ipairs(lines) do
    local new = vim.deepcopy(l == 1 and first or indent)
    H.extend(new, line)
    ret[l] = new
  end
  return ret
end

function M.discussion(discussion, ctx)
  local notes = discussion.notes or {}
  local first = notes[1]
  if not first then
    return {}
  end

  if first.system then
    if ctx.opts.system_notes == false or ctx.markdown == false then
      return {}
    end
    local username = first.author and first.author.username or "ghost"
    local body = (first.body or ""):gsub("\n.*", "")
    local ts = require("tanuki.item").ts(first.created_at)
    return {
      {
        { "  • ", "TanukiSystemNote" },
        { "@" .. username .. " ", "SnacksPickerGitAuthor" },
        { body .. " ", "TanukiSystemNote" },
        { ts and U.reltime(ts) or "", "SnacksPickerGitDate" },
      },
    }
  end

  local ret = {}
  for n, note in ipairs(notes) do
    if n > 1 then
      ret[#ret + 1] = {}
    end
    ret[#ret + 1] = M.note_header(note, ctx, n == 1)
    vim.list_extend(ret, M.note_body(note, ctx))
  end

  local meta = { discussion_id = discussion.id, resolvable = first.resolvable, resolved = first.resolved }
  for _, line in ipairs(ret) do
    line[#line + 1] = { "", meta = meta }
  end
  ret = M.indent(ret, ctx)

  local p = first.position
  if p and (p.new_line or p.old_line) then
    ctx.annotations = ctx.annotations or {}
    table.insert(ctx.annotations, {
      side = p.new_line and "right" or "left",
      file = p.new_path or p.old_path,
      line = p.new_line or p.old_line,
      text = vim.deepcopy(ret),
    })
  end
  return ret
end

function M.annotations(item)
  local ctx = { item = item, opts = require("tanuki").config(), markdown = false }
  for _, discussion in ipairs(item.discussions or {}) do
    M.discussion(discussion, ctx)
  end
  return ctx.annotations
end

return M
