local Api = require("tanuki.api")
local Async = require("snacks.picker.util.async")
local Item = require("tanuki.item")
local Render = require("tanuki.render")

local M = {}
M.__index = M

M.attached = {}
local did_setup = false

function M.new(buf, item)
  local self = setmetatable({}, M)
  self.buf = buf
  self.item = item
  self.opts = vim.deepcopy(require("tanuki").config())
  self.opts.bo = Snacks.config.merge({}, self.opts.bo, {
    buftype = "acwrite",
    swapfile = false,
    filetype = "markdown.gitlab",
  })
  self.opts.wo.winhighlight = self.opts.wo.winhighlight or "Normal:TanukiNormal,NormalFloat:TanukiNormal"
  vim.b[buf].tanuki = { host = item.host, project = item.project, type = item.type, iid = item.iid }
  self:bo()
  self:wo()
  M.attached[buf] = self
  self:keys()
  vim.schedule(function()
    self:render()
  end)
  return self
end

function M:keys()
  local Actions = require("tanuki.actions")
  for name, km in pairs(self.opts.keys or {}) do
    if km ~= false then
      local rhs = km[2]
      local fn
      if type(rhs) == "function" then
        fn = function()
          rhs(self.item, self)
        end
      elseif type(rhs) == "string" and Actions.actions[rhs] then
        fn = function()
          if not Item.is(self.item) then
            return Snacks.notify.warn("Still loading…", { title = "GitLab" })
          end
          local action = Actions.actions[rhs]
          if action.type and action.type ~= self.item.type then
            return
          end
          action.action(self.item, { items = { self.item } })
        end
      else
        Snacks.notify.error(("Invalid GitLab buffer keymap action `%s:%s`"):format(name, tostring(rhs)))
      end
      if fn then
        Snacks.keymap.set(km.mode or "n", km[1], fn, { buffer = self.buf, desc = km.desc })
      end
    end
  end
end

function M:valid()
  return self.buf and M.attached[self.buf] == self and vim.api.nvim_buf_is_valid(self.buf)
end

function M:render(opts)
  if not self:valid() then
    return
  end
  opts = opts or {}
  self.item = Api.get_cached(self.item) or self.item
  self:bo()
  self:wo()

  local item = self.item
  local loaded = Item.is(item) and item.full and not item.dirty and not opts.force

  if Item.is(item) then
    Render.render(self.buf, item, Snacks.config.merge({}, vim.deepcopy(self.opts), { partial = not loaded }))
  end
  if loaded then
    return
  end

  self:cancel()
  local spinner = Snacks.picker.util.spinner(self.buf)
  self.spinner = spinner
  local ref = Item.is(item) and item:ref() or item
  self.task = Async.new(function()
    local it = Api.get(ref, { force = opts.force })
    vim.schedule(function()
      spinner:stop()
      if not self:valid() then
        return
      end
      if not it then
        if not Item.is(self.item) then
          vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, { "Failed to load " .. Item.to_uri(ref) })
        end
        return
      end
      self.item = it
      Render.render(self.buf, it, self.opts)
    end)
  end)
end

function M:cancel()
  if self.task and self.task:running() then
    self.task:abort()
  end
  if self.spinner then
    self.spinner:stop()
    self.spinner = nil
  end
end

function M:bo()
  vim.b[self.buf].snacks_statuscolumn_left = false
  Snacks.util.bo(self.buf, self.opts.bo)
end

function M:wo()
  for _, win in ipairs(vim.fn.win_findbuf(self.buf)) do
    Snacks.util.wo(win, self.opts.wo)
  end
end

function M.attach(buf, item)
  M.setup()
  local ret = M.attached[buf]
  if ret then
    if item then
      ret.item = item
    end
    ret:render()
    return ret
  end
  if not item then
    local name = vim.api.nvim_buf_get_name(buf)
    item = Item.parse_uri(name)
    if not item then
      Snacks.notify.error("Invalid gitlab:// buffer: " .. name)
      return
    end
    item = Api.get_cached(item) or item
  end
  return M.new(buf, item)
end

function M.detach(buf)
  if M.attached[buf] then
    M.attached[buf]:cancel()
  end
  M.attached[buf] = nil
end

function M.setup()
  if did_setup then
    return
  end
  did_setup = true
  local group = vim.api.nvim_create_augroup("tanuki.buf", { clear = true })

  vim.api.nvim_create_autocmd("BufReadCmd", {
    pattern = "gitlab://*",
    group = group,
    callback = function(e)
      vim.schedule(function()
        M.attach(e.buf)
      end)
    end,
  })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    pattern = "gitlab://*",
    group = group,
    callback = function(e)
      vim.bo[e.buf].modified = false
    end,
  })

  vim.api.nvim_create_autocmd("BufWinEnter", {
    pattern = "gitlab://*",
    group = group,
    callback = function(e)
      local self = M.attached[e.buf]
      if self then
        self:bo()
        self:wo()
      end
    end,
  })

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      for _, self in pairs(M.attached) do
        self:render()
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    pattern = "gitlab://*",
    group = group,
    callback = function(ev)
      M.detach(ev.buf)
    end,
  })
end

return M
