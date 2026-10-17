local M = {}
M.__index = M

function M.ts(s)
  if type(s) ~= "string" then
    return
  end
  local y, mo, d, h, mi, sec, tz = s:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)%.?%d*(.*)$")
  if not y then
    return
  end
  local t = os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
    sec = tonumber(sec),
    isdst = false,
  })
  local now = os.time()
  local utc = os.date("!*t", now)
  utc.isdst = false
  t = t + os.difftime(now, os.time(utc))
  local sign, oh, om = tz:match("^([+-])(%d%d):?(%d%d)$")
  if sign then
    local offset = (tonumber(oh) * 60 + tonumber(om)) * 60
    t = sign == "+" and t - offset or t + offset
  end
  return t
end

function M.new(data, ref)
  local self = setmetatable({}, M)
  self.type = ref.type
  self.host = ref.host
  self.project = ref.project
  self.data = {}
  self:update(data)
  return self
end

function M.is(item)
  return getmetatable(item) == M
end

function M.to_uri(ref)
  if ref.uri then
    return ref.uri
  end
  return ("gitlab://%s/%s/-/%s/%d"):format(ref.host, ref.project, require("tanuki.api").segment(ref.type), ref.iid)
end

function M.parse_uri(uri)
  local host, project, segment, iid = uri:match("^gitlab://([^/]+)/(.-)/%-/([%a_]+)/(%d+)$")
  if not host then
    return
  end
  local type = segment == "merge_requests" and "mr" or segment == "issues" and "issue" or nil
  if not type then
    return
  end
  return { host = host, project = project, type = type, iid = tonumber(iid) }
end

function M.color(color)
  local r, g, b = (color or ""):match("^#(%x)(%x)(%x)$")
  if r then
    return ("#%s%s%s%s%s%s"):format(r, r, g, g, b, b)
  end
  return (color or ""):match("^#%x%x%x%x%x%x$") and color or "#888888"
end

local function label(label)
  if type(label) == "string" then
    return { name = label, color = "#888888" }
  end
  return { name = label.name, color = M.color(label.color) }
end

function M:update(data)
  for k, v in pairs(data or {}) do
    self.data[k] = v
  end
  local d = self.data
  self.iid = d.iid or self.iid
  self.uri = M.to_uri({ type = self.type, host = self.host, project = self.project, iid = self.iid })
  self.file = self.uri
  self.title = d.title or ""
  self.body = (d.description or ""):gsub("\r\n", "\n")
  self.url = d.web_url
  self.hash = (self.type == "mr" and "!" or "#") .. tostring(self.iid)
  local state = d.state == "opened" and "open" or d.state or "open"
  self.state = state
  self.draft = self.type == "mr" and (d.draft or d.work_in_progress) or false
  self.status = (self.draft and state == "open") and "draft" or state
  self.author = d.author and d.author.username or nil
  self.labels = vim.tbl_map(label, d.labels or {})
  self.created = M.ts(d.created_at)
  self.updated = M.ts(d.updated_at)
  self.closed = M.ts(d.closed_at)
  self.merged = M.ts(d.merged_at)
  self.discussions = d.discussions
  self.award_emoji = d.award_emoji
  self.approvals = d.approvals
  self.text = table.concat({
    self.hash,
    self.title,
    self.author or "",
    table.concat(
      vim.tbl_map(function(l)
        return l.name
      end, self.labels),
      " "
    ),
  }, " ")
end

function M:reactions()
  local counts = {}
  for _, award in ipairs(self.award_emoji or {}) do
    counts[award.name] = (counts[award.name] or 0) + 1
  end
  local ret = {}
  for name, count in pairs(counts) do
    ret[#ret + 1] = { name = name, count = count }
  end
  table.sort(ret, function(a, b)
    return a.count == b.count and a.name < b.name or a.count > b.count
  end)
  return ret
end

function M:ref()
  return { type = self.type, host = self.host, project = self.project, iid = self.iid, uri = self.uri }
end

return M
