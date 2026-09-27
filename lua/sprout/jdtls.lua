-- jdtls configuration: runs jdtls on a modern JDK, feeds it every installed
-- JDK as a runtime with the project's one as default, loads Lombok, and keeps
-- Eclipse metadata (.project, .classpath, .settings/, .factorypath) out of the
-- project by storing it in the jdtls workspace under stdpath("cache").
local config = require("sprout.config")
local idea = require("sprout.idea")
local jdk = require("sprout.jdk")
local project = require("sprout.project")

local M = {}

local function mason(path)
  local base = vim.env.MASON or (vim.fn.stdpath("data") .. "/mason")
  return base .. "/" .. path
end

function M.executable()
  local exe = mason("bin/jdtls")
  if vim.fn.executable(exe) == 1 then
    return exe
  end
  return vim.fn.exepath("jdtls")
end

function M.lombok()
  local candidates = { mason("share/jdtls/lombok.jar"), "~/.local/share/java/lombok.jar" }
  if config.lombok then
    table.insert(candidates, 1, config.lombok)
  end
  for _, p in ipairs(candidates) do
    p = vim.fn.expand(p)
    if vim.uv.fs_stat(p) then
      return p
    end
  end
end

--- Unique per root, so two services both called "payment" don't share a
--- workspace (and corrupt each other's index).
function M.project_name(root)
  return vim.fs.basename(root) .. "-" .. vim.fn.sha256(root):sub(1, 8)
end

function M.workspace_dir(root)
  return vim.fn.stdpath("cache") .. "/sprout/jdtls/" .. M.project_name(root)
end

--- `jdtls` wrapper command without -data/-configuration.
function M.cmd()
  local cmd = { M.executable() }
  local runner = jdk.find(config.jdtls.java, true)
  if runner then
    cmd[#cmd + 1] = "--java-executable=" .. runner.home .. "/bin/java"
  end
  -- jdtls reads this one as a JVM system property (JLSFsUtils), not as an
  -- LSP setting: it's what keeps .project/.classpath/.settings/ out of the tree.
  cmd[#cmd + 1] = "--jvm-arg=-Djava.import.generatesMetadataFilesAtProjectRoot=false"
  local lombok = M.lombok()
  if lombok then
    cmd[#cmd + 1] = "--jvm-arg=-javaagent:" .. lombok
  end
  for _, a in ipairs(config.jdtls.jvm_args or {}) do
    cmd[#cmd + 1] = "--jvm-arg=" .. a
  end
  return cmd
end

--- Settings that don't depend on the project.
function M.base_settings()
  return vim.tbl_deep_extend("force", {
    java = {
      import = {
        gradle = { enabled = true, wrapper = { enabled = true }, annotationProcessing = { enabled = true } },
        maven = { enabled = true },
        exclusions = { "**/node_modules/**", "**/.metadata/**", "**/archetype-resources/**", "**/META-INF/maven/**", "**/build/**", "**/target/**", "**/bin/**" },
      },
      configuration = { updateBuildConfiguration = "automatic" },
      eclipse = { downloadSources = true },
      maven = { downloadSources = true },
      references = { includeDecompiledSources = true },
      contentProvider = { preferred = "fernflower" },
      signatureHelp = { enabled = true },
      completion = {
        favoriteStaticMembers = {
          "org.junit.jupiter.api.Assertions.*",
          "org.assertj.core.api.Assertions.*",
          "org.mockito.Mockito.*",
          "org.mockito.ArgumentMatchers.*",
          "org.hamcrest.Matchers.*",
          "org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*",
          "org.springframework.test.web.servlet.result.MockMvcResultMatchers.*",
        },
        importOrder = { "java", "javax", "jakarta", "org", "com", "" },
      },
      sources = { organizeImports = { starThreshold = 9999, staticStarThreshold = 9999 } },
    },
  }, config.jdtls.settings or {})
end

--- Settings for one project: its JDK as default runtime and as Gradle's JVM,
--- plus any `jdtls` block from .idea/sprout.json.
function M.settings(root, base)
  local pj = jdk.resolve(root)
  local s = vim.tbl_deep_extend("force", base or M.base_settings(), {
    java = { configuration = { runtimes = jdk.runtimes(pj) } },
  })
  if pj then
    -- Gradle 9 itself needs 17+; the toolchain still compiles for the project JDK.
    local gradle_jvm = pj.major >= 17 and pj or jdk.find(21, true)
    s.java.import.gradle.java = { home = gradle_jvm and gradle_jvm.home }
  end
  return vim.tbl_deep_extend("force", s, idea.settings(root).jdtls or {})
end

--- Complete config for `require("jdtls").start_or_attach` in standalone mode.
function M.config(bufnr)
  local root = project.root(vim.api.nvim_buf_get_name(bufnr or 0))
  if not root then
    return nil
  end
  local ws = M.workspace_dir(root)
  local cmd = M.cmd()
  vim.list_extend(cmd, { "-configuration", ws .. "/config", "-data", ws .. "/workspace" })
  local settings = M.settings(root)
  local ok, blink = pcall(require, "blink.cmp")
  return {
    name = "jdtls",
    cmd = cmd,
    root_dir = root,
    settings = settings,
    init_options = { settings = settings, bundles = M.bundles() },
    capabilities = ok and blink.get_lsp_capabilities() or nil,
  }
end

--- Debug/test bundles from Mason, if installed.
function M.bundles()
  local b = vim.fn.glob(mason("share/java-debug-adapter/com.microsoft.java.debug.plugin-*.jar"), false, true)
  if #b > 0 then
    vim.list_extend(b, vim.fn.glob(mason("share/java-test/*.jar"), false, true))
  end
  return b
end

--- Hook for LazyVim's java extra: adjusts its nvim-jdtls opts in place.
function M.lazyvim_opts(opts)
  local base = vim.tbl_deep_extend("force", opts.settings or {}, M.base_settings())
  opts.root_dir = function(path)
    return project.root(path)
  end
  opts.project_name = function(root)
    return root and M.project_name(root)
  end
  opts.jdtls_config_dir = function(name)
    return vim.fn.stdpath("cache") .. "/sprout/jdtls/" .. name .. "/config"
  end
  opts.jdtls_workspace_dir = function(name)
    return vim.fn.stdpath("cache") .. "/sprout/jdtls/" .. name .. "/workspace"
  end
  opts.cmd = M.cmd()
  opts.settings = base
  -- Per-project settings are decided at attach time.
  local user = opts.jdtls
  opts.jdtls = function(cfg)
    if cfg.root_dir then
      cfg.settings = M.settings(cfg.root_dir, base)
      cfg.init_options = cfg.init_options or {}
      cfg.init_options.settings = cfg.settings
    end
    if type(user) == "function" then
      return user(cfg) or cfg
    elseif type(user) == "table" then
      return vim.tbl_deep_extend("force", cfg, user)
    end
    return cfg
  end
  return opts
end

return M
