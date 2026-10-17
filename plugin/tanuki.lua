if vim.g.loaded_tanuki then
  return
end
vim.g.loaded_tanuki = true

vim.api.nvim_create_user_command("GitLab", function(cmd)
  require("tanuki").command(cmd.fargs)
end, {
  nargs = "*",
  desc = "GitLab issues and merge requests",
  complete = function(_, line)
    return require("tanuki").complete(line)
  end,
})

vim.api.nvim_create_autocmd("BufReadCmd", {
  pattern = "gitlab://*",
  once = true,
  group = vim.api.nvim_create_augroup("tanuki.init", { clear = true }),
  callback = function(e)
    require("tanuki").init()
    vim.schedule(function()
      require("tanuki.buf").attach(e.buf)
    end)
  end,
})
