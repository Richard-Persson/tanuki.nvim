local Api = require("tanuki.api")
local Async = require("snacks.picker.util.async")

local M = {}

local function api_ctx(item)
  return { host = item.host, project = item.project }
end

function M.tpl(str, item)
  return Snacks.picker.util.tpl(str, {
    type = item.type == "mr" and "MR" or "issue",
    hash = item.hash,
    iid = item.iid,
    title = item.title,
    body = item.body,
    project = item.project,
    source_branch = item.data.source_branch,
    target_branch = item.data.target_branch,
  })
end

local function main_win(item, ctx)
  local function check(win)
    if not (win and vim.api.nvim_win_is_valid(win)) then
      return
    end
    local buf = vim.api.nvim_win_get_buf(win)
    local b = vim.b[buf].tanuki
    if b and b.type == item.type and b.iid == item.iid and b.project == item.project then
      ctx.main = win
      return win, buf
    end
  end
  local win, buf = check(ctx.main)
  if win then
    return win, buf
  end
  return check(vim.api.nvim_get_current_win())
end

local function get_meta(item, ctx)
  local win, buf = main_win(item, ctx)
  if not win or not buf then
    return
  end
  local meta = Snacks.picker.highlight.meta(buf)
  local m = meta and meta[vim.api.nvim_win_get_cursor(win)[1]] or nil
  return m, meta, buf, win
end

function M.exec(item, ctx, opts, input, scratch)
  local spinner = require("snacks.picker.util.spinner").loading()
  input = input or { fields = {} }
  local requests = opts.request(item, input)
  requests = requests.path and { requests } or requests
  Async.new(function()
    for _, req in ipairs(requests) do
      local data = Api.request_sync(req)
      if not data then
        return vim.schedule(function()
          spinner:stop()
        end)
      end
    end
    vim.schedule(function()
      spinner:stop()
      if opts.success then
        Snacks.notify.info(M.tpl(opts.success, item), { title = "GitLab" })
      end
      if opts.refresh ~= false then
        Api.refresh(item)
        if ctx.picker and not ctx.picker.closed then
          ctx.picker:refresh()
          ctx.picker:focus()
        end
      end
      if scratch then
        local buf = assert(scratch.buf)
        local fname = vim.api.nvim_buf_get_name(buf)
        scratch:on("WinClosed", function()
          vim.schedule(function()
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
            os.remove(fname)
            os.remove(fname .. ".meta")
          end)
        end, { buf = true })
        scratch:close()
      end
    end)
  end)
end

function M.run(item, ctx, opts)
  if opts.edit then
    return M.edit(item, ctx, opts)
  end
  if opts.confirm then
    return Snacks.picker.util.confirm(M.tpl(opts.confirm, item), function()
      M.exec(item, ctx, opts)
    end)
  end
  M.exec(item, ctx, opts)
end

function M.parse(body, opts)
  local values = {}
  if not opts.fields then
    return body, values
  end
  local known = {}
  for _, f in ipairs(opts.fields) do
    known[f.name] = true
  end
  body = body:gsub("^%-%-%-\n(.-)\n%-%-%-\n%s*", function(fm)
    for _, line in ipairs(vim.split(fm, "\n")) do
      local field, value = line:match("^(%w+):%s*(.-)%s*$")
      if field and known[field] then
        values[field] = value
      elseif line:find("%S") then
        Snacks.notify.warn(("Unknown field `%s` in frontmatter"):format(field or line))
      end
    end
    return ""
  end)
  for _, f in ipairs(opts.fields) do
    if not values[f.name] or values[f.name] == "" then
      Snacks.notify.error(("Missing required field `%s` in frontmatter"):format(f.name))
      return nil, values
    end
  end
  return body, values
end

function M.edit(item, ctx, opts)
  local config = require("tanuki").config()
  local template = opts.template or ""
  if opts.fields and #opts.fields > 0 then
    local fm = { "---" }
    for _, f in ipairs(opts.fields) do
      fm[#fm + 1] = ("%s: {%s}"):format(f.name, f.prop)
    end
    fm[#fm + 1] = "---\n\n"
    template = table.concat(fm, "\n") .. template
  end

  local preview = ctx.picker and ctx.picker.preview and ctx.picker.preview.win:valid() and ctx.picker.preview.win
    or nil
  local actions = preview and preview.opts.actions or {}
  local parent = ctx.main or preview and preview.win or vim.api.nvim_get_current_win()
  local height = config.scratch.height or 15

  local win = Snacks.win.resolve({
    relative = "win",
    width = 0,
    backdrop = false,
    height = height,
    actions = {
      cycle_win = actions.cycle_win,
      preview_scroll_up = actions.preview_scroll_up,
      preview_scroll_down = actions.preview_scroll_down,
    },
    win = parent,
    wo = { winhighlight = "NormalFloat:Normal,FloatTitle:TanukiScratchTitle,FloatBorder:TanukiScratchBorder" },
    border = "top_bottom",
    row = function(w)
      local border = w:border_size()
      return w:parent_size().height - height - border.top - border.bottom
    end,
    on_win = function(w)
      if vim.api.nvim_win_is_valid(parent) then
        local parent_row = vim.api.nvim_win_call(parent, vim.fn.winline) + vim.wo[parent].scrolloff
        local row = vim.api.nvim_win_get_height(parent) - w:size().height
        if parent_row > row then
          vim.api.nvim_win_call(parent, function()
            vim.cmd(("normal! %d%s"):format(parent_row - row, Snacks.util.keycode("<C-e>")))
          end)
        end
      end
      vim.g.snacks_picker_cycle_win = w.win
      vim.schedule(function()
        vim.cmd.startinsert()
      end)
    end,
    footer_keys = { "<c-s>", "R" },
    keys = {
      submit = {
        "<c-s>",
        function(w)
          local body, fields = M.parse(w:text(), opts)
          if not body then
            return
          end
          if not body:find("%S") and not opts.optional then
            return Snacks.notify.warn("Nothing to submit", { title = "GitLab" })
          end
          vim.cmd.stopinsert()
          vim.schedule(function()
            M.exec(item, ctx, opts, { body = body:find("%S") and body or nil, fields = fields }, w)
          end)
        end,
        desc = "Submit",
        mode = { "n", "i" },
      },
    },
  }, preview and {
    keys = {
      ["<a-w>"] = { "cycle_win", mode = { "i", "n" } },
      ["<c-b>"] = { "preview_scroll_up", mode = { "i", "n" } },
      ["<c-f>"] = { "preview_scroll_down", mode = { "i", "n" } },
    },
  } or nil)

  Snacks.scratch({
    ft = "markdown",
    icon = config.icons.logo,
    name = M.tpl(opts.title or "{type} {hash}", item),
    template = M.tpl(template, item),
    filekey = {
      cwd = false,
      branch = false,
      count = false,
      id = ("gitlab/%s/%s/%s/%s"):format(item.project, item.type, item.iid, opts.title or "edit"),
    },
    win = win,
  })
end

local function put(item, body, path)
  return { ctx = api_ctx(item), method = "PUT", path = Api.item_path(item, path), body = body }
end

M.actions = {}

M.actions.gl_open = {
  desc = "Open in buffer",
  icon = " ",
  priority = 100,
  title = "Open {type} {hash} in buffer",
  enabled = function(_, ctx)
    return ctx.picker ~= nil
  end,
  action = function(item, ctx)
    if ctx.picker then
      return Snacks.picker.actions.jump(ctx.picker, item, ctx.action)
    end
  end,
}

M.actions.gl_actions = {
  desc = "Show available actions",
  action = function(item, ctx)
    if ctx.action and ctx.action.cmd and ctx.picker then
      return Snacks.picker.actions.jump(ctx.picker, item, ctx.action)
    end
    main_win(item, ctx)
    require("tanuki.picker").pick("gl_actions", {
      item = item,
      ctx = ctx,
    })
  end,
}

M.actions.gl_refresh = {
  desc = "Refresh",
  icon = " ",
  title = "Refresh {type} {hash}",
  action = function(item)
    Api.refresh(item)
  end,
}

M.actions.gl_browse = {
  desc = "Open in web browser",
  title = "Open {type} {hash} in web browser",
  icon = " ",
  action = function(_, ctx)
    for _, it in ipairs(ctx.items) do
      if it.url then
        vim.ui.open(it.url)
      end
    end
    if ctx.picker then
      ctx.picker.list:set_selected()
    end
  end,
}

M.actions.gl_yank = {
  desc = "Yank URL(s) to clipboard",
  title = "Yank URL of {type} {hash}",
  icon = " ",
  action = function(_, ctx)
    if vim.fn.mode():find("^[vV]") and ctx.picker then
      ctx.picker.list:select()
    end
    local urls = vim.tbl_map(function(it)
      return it.url
    end, ctx.items)
    if ctx.picker then
      ctx.picker.list:set_selected()
    end
    vim.fn.setreg(vim.v.register or "+", table.concat(urls, "\n"), "l")
    Snacks.notify.info("Yanked " .. #urls .. " URL(s)", { title = "GitLab" })
  end,
}

M.actions.gl_comment = {
  desc = "Add comment",
  title = "Comment on {type} {hash}",
  icon = " ",
  priority = 50,
  action = function(item, ctx)
    local m = get_meta(item, ctx)
    if m and m.discussion_id then
      return M.actions.gl_reply.action(item, ctx)
    elseif m and m.diff then
      return M.actions.gl_diff_comment.action(item, ctx)
    end
    M.run(item, ctx, {
      title = "Comment on {type} {hash}",
      success = "Commented on {type} {hash}",
      edit = true,
      request = function(it, input)
        return { ctx = api_ctx(it), method = "POST", path = Api.item_path(it, "notes"), body = { body = input.body } }
      end,
    })
  end,
}

M.actions.gl_thread = {
  desc = "Start a thread",
  title = "Start a resolvable thread on MR {hash}",
  icon = " ",
  type = "mr",
  action = function(item, ctx)
    M.run(item, ctx, {
      title = "Start thread on {type} {hash}",
      success = "Started thread on {type} {hash}",
      edit = true,
      request = function(it, input)
        return {
          ctx = api_ctx(it),
          method = "POST",
          path = Api.item_path(it, "discussions"),
          body = { body = input.body },
        }
      end,
    })
  end,
}

M.actions.gl_reply = {
  desc = "Reply to thread",
  title = "Reply to thread on {type} {hash}",
  icon = " ",
  priority = 150,
  enabled = function(item, ctx)
    local m = get_meta(item, ctx)
    return m and m.discussion_id ~= nil or false
  end,
  action = function(item, ctx)
    local m = get_meta(item, ctx)
    if not (m and m.discussion_id) then
      return Snacks.notify.error("No thread under the cursor", { title = "GitLab" })
    end
    M.run(item, ctx, {
      title = "Reply to thread on {type} {hash}",
      success = "Replied on {type} {hash}",
      edit = true,
      request = function(it, input)
        return {
          ctx = api_ctx(it),
          method = "POST",
          path = Api.item_path(it, "discussions/" .. m.discussion_id .. "/notes"),
          body = { body = input.body },
        }
      end,
    })
  end,
}

local function resolve_action(resolved)
  return {
    desc = resolved and "Resolve thread" or "Unresolve thread",
    title = (resolved and "Resolve" or "Unresolve") .. " thread on MR {hash}",
    icon = resolved and " " or " ",
    priority = 140,
    type = "mr",
    enabled = function(item, ctx)
      local m = get_meta(item, ctx)
      return m and m.resolvable and (m.resolved or false) ~= resolved or false
    end,
    action = function(item, ctx)
      local m = get_meta(item, ctx)
      if not (m and m.discussion_id) then
        return Snacks.notify.error("No thread under the cursor", { title = "GitLab" })
      end
      M.run(item, ctx, {
        success = (resolved and "Resolved" or "Unresolved") .. " thread on MR {hash}",
        request = function(it)
          return {
            ctx = api_ctx(it),
            method = "PUT",
            path = Api.item_path(it, "discussions/" .. m.discussion_id),
            query = { resolved = tostring(resolved) },
          }
        end,
      })
    end,
  }
end
M.actions.gl_resolve = resolve_action(true)
M.actions.gl_unresolve = resolve_action(false)

M.actions.gl_diff_comment = {
  desc = "Comment on diff line",
  title = "Comment on diff in MR {hash}",
  icon = " ",
  priority = 150,
  type = "mr",
  enabled = function(item, ctx)
    local m = get_meta(item, ctx)
    return m and m.diff ~= nil or false
  end,
  action = function(item, ctx)
    local m, meta, buf = get_meta(item, ctx)
    if not (m and m.diff and meta and buf) then
      return Snacks.notify.error("No diff line under the cursor", { title = "GitLab" })
    end
    local refs = item.data.diff_refs
    if not refs then
      return Snacks.notify.error("Missing diff refs for MR " .. item.hash, { title = "GitLab" })
    end
    local diff = m.diff
    local file = item.diff_files and item.diff_files[diff.file] or { old_path = diff.file, map = { left = {}, right = {} } }

    local template = ""
    local visual = ctx.picker and ctx.picker.visual or Snacks.picker.util.visual()
    visual = visual and visual.buf == buf and visual or nil
    if visual then
      local from, to = math.min(visual.pos[1], visual.end_pos[1]), math.max(visual.pos[1], visual.end_pos[1])
      local last = vim.tbl_get(meta, to, "diff") or diff
      local code = {}
      for l = from, to do
        local d = vim.tbl_get(meta, l, "diff")
        if d and d.file == diff.file and d.side == "right" then
          code[#code + 1] = d.code or ""
        end
      end
      if last.side == "right" and #code > 0 then
        diff = last
        template = ("\n```suggestion:-%d+0\n%s\n```\n"):format(#code - 1, table.concat(code, "\n"))
      end
    end

    local position = {
      position_type = "text",
      base_sha = refs.base_sha,
      start_sha = refs.start_sha,
      head_sha = refs.head_sha,
      old_path = file.old_path,
      new_path = diff.file,
    }
    if diff.side == "right" then
      position.new_line = diff.line
      position.old_line = file.map.right[diff.line] -- context lines need both
    else
      position.old_line = diff.line
      position.new_line = file.map.left[diff.line]
    end

    M.run(item, ctx, {
      title = ("Comment on %s:%s%d"):format(vim.fn.fnamemodify(diff.file, ":t"), diff.side:sub(1, 1):upper(), diff.line),
      success = "Commented on MR {hash}",
      edit = true,
      template = template,
      request = function(it, input)
        return {
          ctx = api_ctx(it),
          method = "POST",
          path = Api.item_path(it, "discussions"),
          body = { body = input.body, position = position },
        }
      end,
    })
  end,
}

M.actions.gl_edit = {
  desc = "Edit title and description",
  title = "Edit {type} {hash}",
  icon = " ",
  action = function(item, ctx)
    M.run(item, ctx, {
      title = "Edit {type} {hash}",
      success = "Edited {type} {hash}",
      edit = true,
      optional = true,
      template = "{body}",
      fields = { { name = "title", prop = "title" } },
      request = function(it, input)
        return put(it, { title = input.fields.title, description = input.body or "" })
      end,
    })
  end,
}

M.actions.gl_close = {
  desc = "Close",
  title = "Close {type} {hash}",
  icon = " ",
  enabled = function(item)
    return item.state == "open"
  end,
  action = function(item, ctx)
    M.run(item, ctx, {
      confirm = "Close {type} {hash}?",
      success = "Closed {type} {hash}",
      request = function(it)
        return put(it, { state_event = "close" })
      end,
    })
  end,
}

M.actions.gl_reopen = {
  desc = "Reopen",
  title = "Reopen {type} {hash}",
  icon = " ",
  enabled = function(item)
    return item.state == "closed"
  end,
  action = function(item, ctx)
    M.run(item, ctx, {
      success = "Reopened {type} {hash}",
      request = function(it)
        return put(it, { state_event = "reopen" })
      end,
    })
  end,
}

M.actions.gl_assign_me = {
  desc = "Assign to me",
  title = "Assign {type} {hash} to me",
  icon = " ",
  action = function(item, ctx)
    Async.new(function()
      local user = Api.user(api_ctx(item))
      if not user then
        return
      end
      vim.schedule(function()
        local ids = { user.id }
        for _, a in ipairs(item.data.assignees or {}) do
          if a.id ~= user.id then
            ids[#ids + 1] = a.id
          end
        end
        M.run(item, ctx, {
          success = "Assigned {type} {hash} to you",
          request = function(it)
            return put(it, { assignee_ids = ids })
          end,
        })
      end)
    end)
  end,
}

M.actions.gl_label = {
  desc = "Add/Remove labels",
  title = "Add/Remove labels on {type} {hash}",
  icon = "󰌕 ",
  action = function(item, ctx)
    require("tanuki.picker").pick("gl_labels", {
      item = item,
      confirm = function(picker)
        local add, remove = {}, {}
        for _, it in ipairs(picker:selected({ fallback = true })) do
          table.insert(it.added and remove or add, it.label)
        end
        picker:close()
        M.run(item, ctx, {
          success = "Updated labels of {type} {hash}",
          request = function(i)
            return put(i, { add_labels = table.concat(add, ","), remove_labels = table.concat(remove, ",") })
          end,
        })
      end,
    })
  end,
}

M.actions.gl_react = {
  desc = "Add/Remove reaction",
  title = "React to {type} {hash}",
  icon = " ",
  action = function(item, ctx)
    require("tanuki.picker").pick("gl_reactions", {
      item = item,
      confirm = function(picker)
        local requests = {}
        for _, it in ipairs(picker:selected({ fallback = true })) do
          if it.added then
            requests[#requests + 1] = {
              ctx = api_ctx(item),
              method = "DELETE",
              path = Api.item_path(item, "award_emoji/" .. it.award_id),
            }
          else
            requests[#requests + 1] = {
              ctx = api_ctx(item),
              method = "POST",
              path = Api.item_path(item, "award_emoji"),
              body = { name = it.emoji },
            }
          end
        end
        picker:close()
        M.run(item, ctx, {
          request = function()
            return requests
          end,
        })
      end,
    })
  end,
}

M.actions.gl_diff = {
  desc = "View MR diff",
  title = "View diff of MR {hash}",
  icon = " ",
  priority = 100,
  type = "mr",
  action = function(item)
    require("tanuki.picker").pick("gl_diff", { item = item, show_delay = 0 })
  end,
}

M.actions.gl_checkout = {
  desc = "Checkout MR branch",
  title = "Checkout MR {hash} ({source_branch})",
  icon = " ",
  type = "mr",
  action = function(item)
    Snacks.picker.util.confirm(M.tpl("Checkout MR {hash}?", item), function()
      local remote = require("tanuki").config().remote
      local d = item.data
      local cmds
      if d.source_project_id == d.project_id then
        cmds = {
          { "git", "fetch", remote, d.source_branch },
          { "git", "switch", d.source_branch },
          { "git", "merge", "--ff-only", remote .. "/" .. d.source_branch },
        }
      else -- fork
        local branch = ("mr-%d-%s"):format(item.iid, d.source_branch)
        cmds = {
          { "git", "fetch", remote, ("merge-requests/%d/head:%s"):format(item.iid, branch) },
          { "git", "switch", branch },
        }
      end
      local function step(i)
        if i > #cmds then
          vim.cmd.checktime()
          return Snacks.notify.info(M.tpl("Checked out MR {hash}", item), { title = "GitLab" })
        end
        vim.system(cmds[i], { text = true }, function(out)
          vim.schedule(function()
            if out.code ~= 0 then
              return Snacks.notify.error({ "`" .. table.concat(cmds[i], " ") .. "` failed:", "", out.stderr }, {
                title = "GitLab",
              })
            end
            step(i + 1)
          end)
        end)
      end
      step(1)
    end)
  end,
}

local function approved_by_me(item)
  return item.approvals and item.approvals.user_has_approved
end

M.actions.gl_approve = {
  desc = "Approve",
  title = "Approve MR {hash}",
  icon = " ",
  priority = 60,
  type = "mr",
  enabled = function(item)
    return item.state == "open" and not approved_by_me(item)
  end,
  action = function(item, ctx)
    M.run(item, ctx, {
      success = "Approved MR {hash}",
      request = function(it)
        return { ctx = api_ctx(it), method = "POST", path = Api.item_path(it, "approve") }
      end,
    })
  end,
}

M.actions.gl_unapprove = {
  desc = "Revoke approval",
  title = "Revoke approval of MR {hash}",
  icon = " ",
  type = "mr",
  enabled = function(item)
    return item.state == "open" and approved_by_me(item) or false
  end,
  action = function(item, ctx)
    M.run(item, ctx, {
      success = "Revoked approval of MR {hash}",
      request = function(it)
        return { ctx = api_ctx(it), method = "POST", path = Api.item_path(it, "unapprove") }
      end,
    })
  end,
}

M.actions.gl_merge = {
  desc = "Merge",
  title = "Merge MR {hash}",
  icon = " ",
  type = "mr",
  enabled = function(item)
    return item.state == "open"
  end,
  action = function(item, ctx)
    local choices = {
      { text = "Merge", body = {} },
      { text = "Squash and merge", body = { squash = true } },
      { text = "Merge when pipeline succeeds", body = { merge_when_pipeline_succeeds = true } },
      { text = "Squash and merge when pipeline succeeds", body = { squash = true, merge_when_pipeline_succeeds = true } },
    }
    Snacks.picker.select(choices, {
      prompt = M.tpl("Merge MR {hash} into {target_branch}", item),
      format_item = function(c)
        return c.text
      end,
    }, function(choice)
      if not choice then
        return
      end
      local body = vim.tbl_extend("force", { sha = item.data.sha }, choice.body)
      if item.data.force_remove_source_branch then
        body.should_remove_source_branch = true
      end
      M.run(item, ctx, {
        success = choice.text .. ": MR {hash}",
        request = function(it)
          return put(it, body, "merge")
        end,
      })
    end)
  end,
}

M.actions.gl_rebase = {
  desc = "Rebase source branch",
  title = "Rebase MR {hash} onto {target_branch}",
  icon = "󰚰 ",
  type = "mr",
  enabled = function(item)
    return item.state == "open"
  end,
  action = function(item, ctx)
    M.run(item, ctx, {
      confirm = "Rebase MR {hash} onto {target_branch}?",
      success = "Rebase of MR {hash} started",
      request = function(it)
        return put(it, {}, "rebase")
      end,
    })
  end,
}

local function strip_draft(title)
  return (title:gsub("^%s*%[?[Dd]raft%]?:?%s*", ""):gsub("^%s*%(?[Dd]raft%)%s*", ""))
end

M.actions.gl_ready = {
  desc = "Mark as ready",
  title = "Mark MR {hash} as ready",
  icon = " ",
  type = "mr",
  enabled = function(item)
    return item.state == "open" and item.draft or false
  end,
  action = function(item, ctx)
    M.run(item, ctx, {
      success = "Marked MR {hash} as ready",
      request = function(it)
        return put(it, { title = strip_draft(it.title) })
      end,
    })
  end,
}

M.actions.gl_draft = {
  desc = "Mark as draft",
  title = "Mark MR {hash} as draft",
  icon = " ",
  type = "mr",
  enabled = function(item)
    return item.state == "open" and not item.draft
  end,
  action = function(item, ctx)
    M.run(item, ctx, {
      success = "Marked MR {hash} as draft",
      request = function(it)
        return put(it, { title = "Draft: " .. strip_draft(it.title) })
      end,
    })
  end,
}

M.actions.gl_pipeline = {
  desc = "Open pipeline in browser",
  title = "Open pipeline of MR {hash} in browser",
  icon = " ",
  type = "mr",
  enabled = function(item)
    return (item.data.head_pipeline or item.data.pipeline or {}).web_url ~= nil
  end,
  action = function(item)
    vim.ui.open((item.data.head_pipeline or item.data.pipeline).web_url)
  end,
}

function M.get_actions(item, ctx)
  local ret = {}
  for name, action in pairs(M.actions) do
    local enabled = action.type == nil or action.type == item.type
    enabled = enabled and (action.enabled == nil or action.enabled(item, ctx))
    if enabled and name ~= "gl_actions" then
      local a = setmetatable({}, { __index = action })
      a.desc = action.title and M.tpl(action.title, item) or action.desc or name
      a.name = name
      ret[name] = a
    end
  end
  return ret
end

return M
