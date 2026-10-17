local Actions = require("tanuki.actions")
local Api = require("tanuki.api")

local M = {}

M.actions = {}
for name, a in pairs(Actions.actions) do
  M.actions[name] = {
    desc = a.desc,
    action = function(picker, item, action)
      local items = picker:selected({ fallback = true })
      if item and item.gl_item then
        item = item.gl_item
        items = { item }
      end
      if item then
        return a.action(item, { picker = picker, items = items, action = action })
      end
    end,
  }
end

local function fit(count)
  return {
    preset = "select",
    layout = { max_width = 60 },
    config = function(layout)
      for _, box in ipairs(layout.layout) do
        if box.win == "list" and not box.height then
          box.height = math.max(math.min(count, vim.o.lines * 0.8 - 10), 3)
        end
      end
    end,
  }
end

local function list_finder(type)
  return function(opts, ctx)
    local o = {}
    -- stylua: ignore
    for _, k in ipairs({ "state", "limit", "author", "assignee", "reviewer", "label", "milestone", "scope", "draft", "target_branch", "source_branch", "query" }) do
      o[k] = opts[k]
    end
    o.search = ctx.filter.search ~= "" and ctx.filter.search or nil
    return function(cb)
      for _, item in ipairs(Api.list(type, opts.gl, o)) do
        cb(item)
      end
    end
  end
end

function M.format(item, picker)
  local ret = {}
  local a = Snacks.picker.util.align
  local config = require("tanuki").config()

  local icons = config.icons[item.type]
  local status = icons[item.status] and item.status or "other"
  ret[#ret + 1] = { a(icons[status], 2), "Tanuki" .. Snacks.picker.util.title(item.type) .. Snacks.picker.util.title(status) }
  ret[#ret + 1] = { " " }
  ret[#ret + 1] = { a(item.hash, 7), "SnacksPickerDimmed" }

  item.msg = item.title
  Snacks.picker.highlight.extend(ret, Snacks.picker.format.commit_message(item, picker))

  if item.author then
    ret[#ret + 1] = { " " }
    ret[#ret + 1] = { "@" .. item.author, "SnacksPickerGitAuthor" }
  end

  for _, label in ipairs(item.labels) do
    ret[#ret + 1] = { " " }
    vim.list_extend(ret, Snacks.picker.highlight.badge(label.name, label.color))
  end
  return ret
end

function M.preview(ctx)
  local config = require("tanuki").config()
  local item = ctx.item
  item.wo = config.wo
  item.bo = config.bo
  item.preview_title = ("%s %s %s"):format(config.icons.logo, item.type == "mr" and "MR" or "Issue", item.hash)
  return Snacks.picker.preview.file(ctx)
end

function M.preview_diff(ctx)
  Snacks.picker.preview.diff(ctx)
  local item = ctx.item.gl_item
  if item then
    vim.b[ctx.buf].tanuki = { host = item.host, project = item.project, type = item.type, iid = item.iid }
  end
end

local function checkbox(item, picker)
  local added = item.added
  if picker.list:is_selected(item) then
    added = not added
  end
  return { added and "󰱒 " or "󰄱 ", "SnacksPickerDelim" }
end

local function unified(diffs)
  local lines = {}
  local files = {}
  for _, f in ipairs(diffs) do
    local old, new = f.old_path, f.new_path
    lines[#lines + 1] = ("diff --git a/%s b/%s"):format(old, new)
    if f.new_file then
      lines[#lines + 1] = "new file mode " .. (f.b_mode or "100644")
    elseif f.deleted_file then
      lines[#lines + 1] = "deleted file mode " .. (f.a_mode or "100644")
    elseif f.renamed_file then
      lines[#lines + 1] = "rename from " .. old
      lines[#lines + 1] = "rename to " .. new
    end
    lines[#lines + 1] = "--- " .. (f.new_file and "/dev/null" or ("a/" .. old))
    lines[#lines + 1] = "+++ " .. (f.deleted_file and "/dev/null" or ("b/" .. new))

    local map = { left = {}, right = {} }
    local o, n = 0, 0
    for _, line in ipairs(vim.split((f.diff or ""):gsub("\n$", ""), "\n", { plain = true })) do
      if line ~= "" or o > 0 or n > 0 then
        lines[#lines + 1] = line
      end
      local a, c = line:match("^@@ %-(%d+),?%d* %+(%d+),?%d* @@")
      local first = line:sub(1, 1)
      if a then
        o, n = tonumber(a), tonumber(c)
      elseif first == " " then
        map.right[n], map.left[o] = o, n
        o, n = o + 1, n + 1
      elseif first == "-" then
        o = o + 1
      elseif first == "+" then
        n = n + 1
      end
    end
    files[new] = { old_path = old, map = map }
  end
  return table.concat(lines, "\n"), files
end

local function actions_finder(item, action_ctx, current)
  return function(_, ctx)
    return function(cb)
      local it = item
      if not it and current then
        local mr = Api.current_mr(current.gl, current.branch)
        it = mr and Api.get(mr)
      end
      if not it then
        ctx.async:schedule(function()
          Snacks.notify.warn("No open merge request for the current branch", { title = "GitLab" })
        end)
        return
      end
      local actx = action_ctx or { items = { it } }
      local actions = ctx.async:schedule(function()
        return Actions.get_actions(it, actx)
      end)
      local items = {}
      for name, action in pairs(actions) do
        items[#items + 1] = {
          text = Snacks.picker.util.text(action, { "name", "desc" }),
          name = name,
          desc = action.desc,
          action = action,
          gl = it,
          action_ctx = actx,
        }
      end
      table.sort(items, function(a, b)
        local pa, pb = a.action.priority or 0, b.action.priority or 0
        if pa ~= pb then
          return pa > pb
        end
        return a.desc < b.desc
      end)
      for _, i in ipairs(items) do
        cb(i)
      end
    end
  end
end

local function actions_confirm(picker, it, action)
  if not it then
    return
  end
  local ctx = it.action_ctx
  ctx.action = action
  picker:close()
  if ctx.picker and not ctx.picker.closed then
    ctx.picker:focus()
  end
  it.action.action(it.gl, ctx)
end

M.sources = {
  gl_issue = {
    title = "  Issues",
    needs_ctx = true,
    finder = list_finder("issue"),
    format = M.format,
    preview = M.preview,
    sort = { fields = { "score:desc", "idx" } },
    supports_live = true,
    live = true,
    confirm = "gl_actions",
    actions = M.actions,
    win = {
      input = {
        keys = {
          ["<a-b>"] = { "gl_browse", mode = { "n", "i" } },
          ["<c-y>"] = { "gl_yank", mode = { "n", "i" } },
        },
      },
      list = { keys = { ["y"] = { "gl_yank", mode = { "n", "x" } } } },
    },
  },
  gl_diff = {
    title = "  Merge Request Diff",
    group = true,
    format = "git_status",
    preview = M.preview_diff,
    actions = M.actions,
    win = {
      preview = {
        keys = {
          ["a"] = { "gl_comment", mode = { "n", "x" } },
          ["<cr>"] = { "gl_actions", mode = { "n", "x" } },
        },
      },
    },
    finder = function(opts, ctx)
      local Diff = require("snacks.picker.source.diff")
      local Render = require("tanuki.render")
      opts.previewers.diff.style = "fancy"
      local ref = opts.item:ref()
      return function(cb)
        local item = Api.get(ref)
        local diffs = item and Api.diffs(item)
        if not (item and diffs) then
          return
        end
        local text, files = unified(diffs)
        item.diff_files = files
        local annotations = ctx.async:schedule(function()
          return Render.annotations(item)
        end)
        Diff.diff(ctx:opts({ diff = text, annotations = annotations }), ctx)(function(it)
          it.gl_item = item
          cb(it)
        end)
      end
    end,
  },
  gl_actions = {
    title = "  Actions",
    layout = { preset = "select", layout = { max_width = 60 } },
    main = { current = true },
    format = function(item, picker)
      local ret = {}
      if item.action.icon then
        ret[#ret + 1] = { item.action.icon, "Special" }
        ret[#ret + 1] = { " " }
      end
      local idx = tostring(item.idx)
      ret[#ret + 1] = { (" "):rep(#tostring(picker:count()) - #idx) .. idx .. ".", "SnacksPickerIdx" }
      ret[#ret + 1] = { " " }
      ret[#ret + 1] = { item.desc }
      Snacks.picker.highlight.highlight(ret, { ["[#!]%d+"] = "Number" })
      return ret
    end,
  },
  gl_labels = {
    title = "󰌕  Labels",
    layout = { preset = "select", layout = { max_width = 50 } },
    main = { current = true },
    format = function(item, picker)
      local ret = { checkbox(item, picker), { " " } }
      vim.list_extend(ret, Snacks.picker.highlight.badge(item.label, item.color))
      if item.description then
        ret[#ret + 1] = { " " }
        ret[#ret + 1] = { item.description, "SnacksPickerComment" }
      end
      return ret
    end,
    finder = function(opts)
      local item = opts.item
      return function(cb)
        local labels = Api.paginate({ ctx = { host = item.host, project = item.project }, path = "labels" }) or {}
        local added = {}
        for _, l in ipairs(item.labels) do
          added[l.name] = true
        end
        table.sort(labels, function(a, b)
          if (added[a.name] or false) ~= (added[b.name] or false) then
            return added[a.name] == true
          end
          return a.name:lower() < b.name:lower()
        end)
        for _, l in ipairs(labels) do
          cb({
            text = l.name,
            label = l.name,
            color = require("tanuki.item").color(l.color),
            description = l.description,
            added = added[l.name] == true,
          })
        end
      end
    end,
  },
  gl_reactions = {
    title = "  Reactions",
    layout = { preset = "select", layout = { max_width = 40 } },
    main = { current = true },
    format = function(item, picker)
      local config = require("tanuki").config()
      return { checkbox(item, picker), { " " }, { config.icons.emoji[item.emoji] or item.emoji }, { " " }, { item.emoji, "SnacksPickerComment" } }
    end,
    finder = function(opts)
      local config = require("tanuki").config()
      return function(cb)
        local item = Api.get(opts.item:ref()) or opts.item
        local user = Api.user({ host = item.host, project = item.project }) or {}
        local mine = {}
        for _, award in ipairs(item.award_emoji or {}) do
          if award.user and award.user.username == user.username then
            mine[award.name] = award.id
          end
        end
        local names = vim.tbl_keys(config.icons.emoji)
        for name in pairs(mine) do
          if not config.icons.emoji[name] then
            names[#names + 1] = name
          end
        end
        table.sort(names)
        for _, name in ipairs(names) do
          cb({ text = name, emoji = name, added = mine[name] ~= nil, award_id = mine[name] })
        end
      end
    end,
  },
}
M.sources.gl_mr = vim.tbl_extend("force", M.sources.gl_issue, {
  title = "  Merge Requests",
  finder = list_finder("mr"),
})

function M.pick(name, opts)
  require("tanuki").init()
  opts = opts or {}
  local source = M.sources[name]
  assert(source, "Unknown GitLab picker: " .. name)
  source = vim.deepcopy(source)
  if source.needs_ctx then
    opts.gl = Api.context(opts)
    if not opts.gl then
      return
    end
    source.title = source.title .. " · " .. opts.gl.project
  end
  source.needs_ctx = nil

  if name == "gl_actions" then
    local item = opts.item
    local action_ctx = opts.ctx
    opts.item, opts.ctx = nil, nil
    source.confirm = actions_confirm
    if item then
      source.title = Actions.tpl("  Actions · {type} {hash}", item)
      source.layout = fit(vim.tbl_count(Actions.get_actions(item, action_ctx or { items = { item } })))
      source.finder = actions_finder(item, action_ctx)
    else
      local gl = Api.context(opts)
      if not gl then
        return
      end
      local branch = vim.trim(vim.fn.system({ "git", "branch", "--show-current" }))
      source.finder = actions_finder(nil, nil, { gl = gl, branch = branch })
    end
  elseif name == "gl_reactions" then
    source.layout = fit(vim.tbl_count(require("tanuki").config().icons.emoji))
  end

  return Snacks.picker.pick(vim.tbl_extend("force", source, { source = name }, opts))
end

return M
