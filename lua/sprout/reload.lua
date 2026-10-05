-- Build file changed → reload the classpath, IntelliJ style.
--
-- jdtls already watches pom.xml / *.gradle(.kts) / libs.versions.toml and, in
-- "interactive" mode, asks the client whether to re-import through a
-- `language/actionableNotification`. nvim-jdtls neither advertises nor handles
-- that, so the question was silently dropped. We do both, and remember
-- "always"/"never" per project in .idea/sprout.json.
local idea = require("sprout.idea")

local M = {}

M.CAPABILITIES = { actionableNotificationSupported = true }

-- .idea/sprout.json `reload` → jdtls `java.configuration.updateBuildConfiguration`
local MODES = { ask = "interactive", auto = "automatic", never = "disabled" }

function M.mode(root)
  return MODES[idea.settings(root).reload or "ask"] or "interactive"
end

-- Build files per client that are waiting on one prompt.
local pending = {} ---@type table<integer, table<string, true>>
local prompting = {} ---@type table<integer, boolean>
local watching = {} ---@type table<integer, boolean>

--- Say when the re-import has finished, so you know completion is up to date.
local function watch_progress(client)
  if watching[client.id] then
    return
  end
  watching[client.id] = true
  vim.api.nvim_create_autocmd("LspProgress", {
    callback = function(ev)
      local v = ev.data.params.value
      if ev.data.client_id ~= client.id or type(v) ~= "table" or v.kind ~= "end" then
        return
      end
      local text = (v.title or "") .. " " .. (v.message or "")
      if text:find("Synchronizing projects", 1, true) or text:find("Importing", 1, true) then
        watching[client.id] = nil
        vim.notify(("sprout: %s classpath updated"):format(vim.fs.basename(client.root_dir or "")))
        return true -- drop this autocmd
      end
    end,
  })
end

--- Ask jdtls to re-import the given build files (or every one under the root).
---@param client vim.lsp.Client
---@param uris? string[]
function M.update(client, uris)
  if not uris or #uris == 0 then
    uris = {}
    local res = vim.system({
      "rg", "--files", "--glob", "{pom.xml,build.gradle,build.gradle.kts}",
      "--glob", "!**/build/**", "--glob", "!**/target/**", client.root_dir,
    }, { text = true }):wait()
    for f in (res.stdout or ""):gmatch("[^\n]+") do
      uris[#uris + 1] = vim.uri_from_fname(f)
    end
  end
  if #uris == 0 then
    return vim.notify("sprout: no build files found", vim.log.levels.WARN)
  end
  watch_progress(client)
  client:notify("java/projectConfigurationsUpdate", {
    identifiers = vim.tbl_map(function(u)
      return { uri = u }
    end, uris),
  })
  vim.notify(("sprout: reloading %s…"):format(vim.fs.basename(client.root_dir or "")))
end

--- Switch a running jdtls between ask / auto / never.
local function set_mode(client, reload)
  local s = vim.deepcopy(idea.settings(client.root_dir))
  s.reload = reload
  idea.write_settings(client.root_dir, s)
  client.settings = vim.tbl_deep_extend("force", client.settings or {}, {
    java = { configuration = { updateBuildConfiguration = MODES[reload] } },
  })
  client:notify("workspace/didChangeConfiguration", { settings = client.settings })
end

local CHOICES = {
  { label = "Reload now", run = function(c, uris) M.update(c, uris) end },
  {
    label = "Always reload this project",
    run = function(c, uris)
      -- Update first: a didChangeConfiguration sent just before it makes jdtls drop the update.
      M.update(c, uris)
      set_mode(c, "auto")
    end,
  },
  { label = "Not now", run = function() end },
  { label = "Never for this project", run = function(c) set_mode(c, "never") end },
}

local function prompt(client)
  prompting[client.id] = true
  vim.ui.select(CHOICES, {
    prompt = ("Build file changed in %s. Reload classpath?"):format(vim.fs.basename(client.root_dir or "")),
    format_item = function(c)
      return c.label
    end,
  }, function(choice)
    prompting[client.id] = nil
    local uris = vim.tbl_keys(pending[client.id] or {})
    pending[client.id] = nil
    if choice then
      choice.run(client, uris)
    end
  end)
end

--- `language/actionableNotification` handler.
function M.on_actionable(_, result, ctx)
  local client = vim.lsp.get_client_by_id(ctx.client_id)
  if not client or not result then
    return
  end
  local cmd = (result.commands or {})[1]
  if not cmd or cmd.command ~= "java.projectConfiguration.status" then
    -- Some other actionable message: show it, there's nothing we can run.
    local levels = { vim.log.levels.ERROR, vim.log.levels.WARN, vim.log.levels.INFO }
    vim.notify("jdtls: " .. (result.message or ""), levels[result.severity] or vim.log.levels.INFO)
    return
  end
  -- The build file comes as the first argument, a URI or a TextDocumentIdentifier.
  local arg = (cmd.arguments or {})[1]
  local uri = type(arg) == "table" and arg.uri or arg
  pending[client.id] = pending[client.id] or {}
  if type(uri) == "string" then
    pending[client.id][uri] = true
  end
  -- Several build files changing at once (a git pull) get one prompt.
  if not prompting[client.id] then
    vim.schedule(function()
      prompt(client)
    end)
  end
end

--- Wire the capability, handler and project's reload mode into a jdtls config.
function M.apply(cfg)
  local ok, caps = pcall(require, "jdtls.capabilities")
  cfg.init_options = cfg.init_options or {}
  cfg.init_options.extendedClientCapabilities = vim.tbl_extend(
    "force",
    cfg.init_options.extendedClientCapabilities or (ok and vim.deepcopy(caps)) or {},
    M.CAPABILITIES
  )
  cfg.handlers = cfg.handlers or {}
  cfg.handlers["language/actionableNotification"] = M.on_actionable
  return cfg
end

--- :Sprout reload
function M.reload()
  local project = require("sprout.project")
  local root = project.root()
  local p = project.get(root)
  if p and p.tool == "kotlin" then
    return require("sprout.toolchain").refresh(root, true)
  end
  for _, client in ipairs(vim.lsp.get_clients({ name = "jdtls" })) do
    if client.root_dir == root then
      return M.update(client)
    end
  end
  vim.notify("sprout: jdtls isn't running for this project", vim.log.levels.WARN)
end

return M
