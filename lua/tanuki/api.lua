local Async = require("snacks.picker.util.async")
local Item = require("tanuki.item")

local M = {}

local cache = setmetatable({}, { __mode = "v" })
local ctx_cache = {}
local user_cache = {}

function M.encode(s)
  return (tostring(s):gsub("[^%w%-%._~]", function(c)
    return ("%%%02X"):format(c:byte())
  end))
end

function M.parse_remote(url)
  url = vim.trim(url)
  local host, path
  local rest = url:match("^%a[%w+.-]*://(.+)$")
  if rest then
    local authority, p = rest:match("^([^/]+)/(.+)$")
    if not authority then
      return
    end
    host, path = authority:gsub("^.*@", ""):gsub(":%d*$", ""), p
  else
    local a, p = url:match("^([^:/]+):(.+)$")
    if not a then
      return
    end
    host, path = a:gsub("^.*@", ""), p
  end
  path = path:gsub("/$", ""):gsub("%.git$", "")
  return host, path
end

function M.context(opts)
  opts = opts or {}
  local config = require("tanuki").config()
  local project = opts.project or opts.repo
  if opts.host and project then
    return { host = opts.host, project = project }
  end
  local root = Snacks.git.get_root(opts.cwd or vim.uv.cwd() or ".")
  local key = (root or "") .. "::" .. config.remote
  if ctx_cache[key] == nil then
    ctx_cache[key] = false
    if root then
      local out = vim.system({ "git", "-C", root, "remote", "get-url", config.remote }, { text = true }):wait()
      local host, path = M.parse_remote(out.code == 0 and out.stdout or "")
      if host and path then
        ctx_cache[key] = { host = config.hosts[host] or host, project = path }
      end
    end
  end
  local ret = ctx_cache[key]
  if not ret then
    if not (opts.host and project) and opts.notify ~= false then
      Snacks.notify.error({
        "Could not detect a GitLab project.",
        "Run inside a git repo with a GitLab `" .. config.remote .. "` remote, or pass `host` and `project`.",
      }, { title = "GitLab" })
    end
    return
  end
  return { host = opts.host or ret.host, project = project or ret.project }
end

function M.endpoint(ctx, path)
  if path:sub(1, 1) == "/" then
    return path:sub(2)
  end
  return "projects/" .. M.encode(ctx.project) .. (path == "" and "" or "/" .. path)
end

local function querystring(query)
  local parts = {}
  for k, v in pairs(query or {}) do
    if v ~= nil and v ~= "" then
      parts[#parts + 1] = M.encode(k) .. "=" .. M.encode(tostring(v))
    end
  end
  table.sort(parts)
  return #parts > 0 and ("?" .. table.concat(parts, "&")) or ""
end

local function error_message(out)
  local ok, data = pcall(vim.json.decode, out)
  if ok and type(data) == "table" then
    local msg = data.message or data.error
    if type(msg) == "table" then
      local ret = {}
      for k, v in pairs(msg) do
        ret[#ret + 1] = type(k) == "string" and (k .. ": " .. vim.inspect(v)) or tostring(v)
      end
      return table.concat(ret, "\n")
    end
    return msg and tostring(msg) or nil
  end
end

function M.request(cb, opts)
  local endpoint = M.endpoint(opts.ctx, opts.path) .. querystring(opts.query)
  local args = { "api", endpoint, "--method", opts.method or "GET", "--hostname", opts.ctx.host }
  local input
  if opts.body then
    input = vim.json.encode(opts.body)
    vim.list_extend(args, { "--header", "Content-Type: application/json", "--input", "-" })
  end
  return require("snacks.util.spawn").new({
    cmd = "glab",
    args = args,
    input = input,
    timeout = 30000,
    on_exit = function(proc, failed)
      if failed then
        local err = error_message(proc:out()) or vim.trim(proc:err())
        err = err ~= "" and err or ("glab exited with code " .. tostring(proc.code))
        if not proc.aborted then
          vim.schedule(function()
            if opts.notify ~= false then
              local msg = { ("`%s %s`"):format(opts.method or "GET", endpoint), "", err }
              -- gitlab answers 404 instead of 401 for private projects
              if err:find("401") or err:find("404 Project Not Found") then
                vim.list_extend(msg, {
                  "",
                  ("Not logged in to `%s`? Run `glab auth login --hostname %s`"):format(opts.ctx.host, opts.ctx.host),
                })
              end
              Snacks.notify.error(msg, { title = "GitLab API Error" })
            end
          end)
        end
        return cb(nil, err)
      end
      local out = proc:out()
      if not out:find("%S") then
        return cb({})
      end
      local ok, data = pcall(vim.json.decode, out, { luanil = { object = true, array = true } })
      if not ok then
        return cb(nil, "Invalid JSON response: " .. tostring(data))
      end
      cb(data)
    end,
  })
end

function M.request_sync(opts)
  local ret, err
  M.request(function(data, e)
    ret, err = data, e
  end, opts):wait()
  return ret, err
end

function M.paginate(opts, max)
  max = max or 1000
  local ret = {}
  local page = 1
  while #ret < max do
    local q = vim.tbl_extend("force", opts.query or {}, { per_page = 100, page = page })
    local data, err = M.request_sync(vim.tbl_extend("force", opts, { query = q }))
    if not data then
      return #ret > 0 and ret or nil, err
    end
    vim.list_extend(ret, data)
    if #data < 100 then
      break
    end
    page = page + 1
  end
  return ret
end

function M.all(requests)
  local results = {}
  local procs = {}
  for i, req in ipairs(requests) do
    procs[i] = M.request(function(data, err)
      results[i] = { data = data, err = err }
    end, req)
  end
  for _, proc in ipairs(procs) do
    proc:wait()
  end
  return results
end

function M.segment(type)
  return type == "mr" and "merge_requests" or "issues"
end

function M.item_path(item, path)
  return ("%s/%d%s"):format(M.segment(item.type), item.iid, path and ("/" .. path) or "")
end

function M.user(ctx)
  if not user_cache[ctx.host] then
    user_cache[ctx.host] = M.request_sync({ ctx = ctx, path = "/user" })
  end
  return user_cache[ctx.host]
end

local states = {
  open = "opened",
  opened = "opened",
  closed = "closed",
  merged = "merged",
  locked = "locked",
}

function M.list(type, ctx, opts)
  local config = require("tanuki").config()
  opts = vim.deepcopy(opts)
  for _, field in ipairs({ "author", "assignee", "reviewer" }) do
    if opts[field] == "@me" then
      local user = M.user(ctx)
      if not user then
        return {}
      end
      opts[field] = user.username
    end
  end
  local query = vim.tbl_extend("force", {
    state = states[opts.state or "open"],
    search = opts.search,
    author_username = opts.author,
    assignee_username = opts.assignee,
    reviewer_username = type == "mr" and opts.reviewer or nil,
    labels = opts.label,
    milestone = opts.milestone,
    scope = opts.scope,
    target_branch = type == "mr" and opts.target_branch or nil,
    source_branch = type == "mr" and opts.source_branch or nil,
    order_by = "updated_at",
    sort = "desc",
    with_labels_details = "true",
    per_page = math.min(opts.limit or config.limit, 100),
  }, opts.query or {})
  if type == "mr" and opts.draft ~= nil then
    query.draft = opts.draft and "yes" or "no"
  end
  local data = M.request_sync({ ctx = ctx, path = M.segment(type), query = query }) or {}
  local ret = {}
  for _, it in ipairs(data) do
    ret[#ret + 1] = M.cache_set(Item.new(it, { type = type, host = ctx.host, project = ctx.project }))
  end
  return ret
end

function M.get_cached(ref)
  if Item.is(ref) then
    return ref
  end
  return cache[Item.to_uri(ref)]
end

function M.cache_set(item)
  local cached = cache[item.uri]
  if cached and cached ~= item then
    cached:update(item.data)
    return cached
  end
  cache[item.uri] = item
  return item
end

function M.get(ref, opts)
  opts = opts or {}
  local item = M.get_cached(ref)
  if item and item.full and not item.dirty and not opts.force then
    return item
  end
  local ctx = { host = ref.host, project = ref.project }
  local requests = {
    { ctx = ctx, path = M.item_path(ref), query = { with_labels_details = "true" } },
    { ctx = ctx, path = M.item_path(ref, "award_emoji"), query = { per_page = 100 }, notify = false },
  }
  if ref.type == "mr" then
    requests[#requests + 1] = { ctx = ctx, path = M.item_path(ref, "approvals"), notify = false }
  end
  local results = M.all(requests)
  local data = results[1].data
  if not data then
    return
  end
  local discussions = M.paginate({ ctx = ctx, path = M.item_path(ref, "discussions") }) or {}

  data.award_emoji = results[2].data
  data.approvals = results[3] and results[3].data or nil
  data.discussions = discussions
  item = item or Item.new(data, { type = ref.type, host = ref.host, project = ref.project })
  item:update(data)
  item.full = true
  item.dirty = false
  return M.cache_set(item)
end

function M.refresh(item)
  item.dirty = true
  cache[item.uri] = item
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) == item.uri then
      require("tanuki.buf").attach(buf, item)
    end
  end
end

function M.current_mr(ctx, branch)
  if branch == "" then
    return
  end
  local items = M.list("mr", ctx, { state = "open", source_branch = branch, limit = 1 })
  return items[1]
end

function M.diffs(item)
  local ctx = { host = item.host, project = item.project }
  local ret = M.paginate({ ctx = ctx, path = M.item_path(item, "diffs"), notify = false })
  if ret then
    return ret
  end
  -- gitlab < 15.7
  local data = M.request_sync({ ctx = ctx, path = M.item_path(item, "changes") })
  return data and data.changes or nil
end

return M
