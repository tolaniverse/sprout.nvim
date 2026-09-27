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
  run = {
    -- Terminal height for run/build output.
    height = 15,
    debug_port = 5005,
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
