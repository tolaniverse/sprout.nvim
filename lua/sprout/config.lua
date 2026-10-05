---@class sprout.Config
local defaults = {
  -- Start jdtls on java buffers yourself. Leave false under LazyVim's java
  -- extra, which starts it for you (see `require("sprout.lazyvim")`).
  jdtls = {
    enabled = false,
    -- JDK major that runs jdtls itself (needs 21+). The project JDK is separate.
    java = 21,
    -- Extra JVM args for the jdtls process.
    jvm_args = { "-Xmx2g" },
    -- Merged into the jdtls `settings` table for every project.
    settings = {},
  },
  -- Where Lombok comes from. nil = Mason's jdtls copy, then ~/.local/share/java.
  lombok = nil,
  -- Extra JDK homes to consider, on top of SDKMAN, JAVA_HOME and
  -- /Library/Java/JavaVirtualMachines.
  jdks = {},
  -- Spring Boot language server (Mason: vscode-spring-boot-tools), started
  -- only in Spring Boot projects: application.yml/properties completion,
  -- validation and hover; @Value completion; bean/endpoint symbols.
  spring_ls = {
    enabled = true,
    java = 21, -- needs 21+
    jvm_args = { "-Xmx1024m" },
  },
  run = {
    -- Terminal height for run/build output.
    height = 15,
    debug_port = 5005,
    -- nvim-dap adapter for :Sprout debug/attach: "java" (java-debug, via
    -- jdtls) or "kotlin" (Mason's kotlin-debug-adapter). nil = "kotlin" in
    -- projects with Kotlin sources when that adapter is installed.
    debug_adapter = nil,
  },
  kotlin_toolchain = {
    -- The toolchain's shared cache, where it keeps dependency jars. nil = its
    -- default (~/Library/Caches/JetBrains/Kotlin on macOS). Set it if you pass
    -- --shared-cache-dir.
    cache_dir = nil,
  },
  ktor = {
    -- Run Ktor apps with -Dio.ktor.development=true (detailed errors, and
    -- auto-reload when you also run a continuous build).
    development = true,
  },
}

local M = {}

---@type typeof(defaults)
M.options = vim.deepcopy(defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
end

return setmetatable(M, {
  __index = function(_, k)
    return M.options[k]
  end,
})
