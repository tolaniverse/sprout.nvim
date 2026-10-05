local M = {}

function M.check()
  local h = vim.health
  h.start("sprout " .. require("sprout").version)
  local jdk = require("sprout.jdk")
  local jdtls = require("sprout.jdtls")
  local config = require("sprout.config")

  local list = jdk.list()
  if #list == 0 then
    h.error("no JDKs found (SDKMAN, JAVA_HOME, /Library/Java/JavaVirtualMachines)")
  else
    for _, j in ipairs(list) do
      h.ok(("JDK %d  %s  %s"):format(j.major, j.id, j.home))
    end
  end
  local runner = jdk.find(config.jdtls.java, true)
  if runner then
    h.ok("jdtls runs on " .. runner.id)
  else
    h.error("jdtls needs JDK " .. config.jdtls.java .. "+: `sdk install java 21-tem`")
  end
  if jdtls.executable() ~= "" then
    h.ok("jdtls: " .. jdtls.executable())
  else
    h.error("jdtls not found: `:MasonInstall jdtls`")
  end
  if jdtls.lombok() then
    h.ok("lombok: " .. jdtls.lombok())
  else
    h.warn("lombok.jar not found; Lombok code will show errors")
  end
  if #jdtls.bundles() > 0 then
    h.ok("debug/test bundles: " .. #jdtls.bundles())
  else
    h.warn("java-debug-adapter / java-test not installed: `:MasonInstall java-debug-adapter java-test`")
  end
  local spring_ls = require("sprout.spring_ls")
  if not config.spring_ls.enabled then
    h.info("Spring Boot language server disabled")
  elseif spring_ls.jar() then
    h.ok("Spring Boot language server: " .. spring_ls.jar() .. " (" .. #spring_ls.bundles() .. " jdtls bundles)")
  else
    h.warn("Spring Boot language server not installed: `:MasonInstall vscode-spring-boot-tools`")
  end
  if vim.fn.executable("kotlin-debug-adapter") == 1
    or vim.fn.executable(vim.fn.stdpath("data") .. "/mason/bin/kotlin-debug-adapter") == 1
  then
    h.ok("kotlin-debug-adapter found (debugging Kotlin projects)")
  else
    h.info("kotlin-debug-adapter not installed; needed to debug Kotlin code: `:MasonInstall kotlin-debug-adapter`")
  end
  for _, exe in ipairs({ "rg", "bleep", "gradle", "mvn", "kotlin" }) do
    if vim.fn.executable(exe) == 1 then
      h.ok(exe .. " found")
    else
      h.info(exe .. " not on PATH (wrappers are used when present)")
    end
  end
  if not pcall(require, "jdtls") then
    h.error("mfussenegger/nvim-jdtls is not installed")
  end
end

return M
