if vim.g.loaded_sprout then
  return
end
vim.g.loaded_sprout = true

vim.api.nvim_create_user_command("Sprout", function(a)
  require("sprout").command(a)
end, {
  nargs = "*",
  bang = true,
  desc = "sprout: Spring Boot / Ktor / JVM project commands",
  complete = function(...)
    return require("sprout").complete(...)
  end,
})
