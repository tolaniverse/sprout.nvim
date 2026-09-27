-- Spring Boot language server (the one inside VS Code's "Spring Boot Tools",
-- installed by Mason as vscode-spring-boot-tools).
--
-- It has no classpath of its own: it asks the editor (`sts/javaType`,
-- `sts/addClasspathListener`, …) and the editor forwards each request to jdtls
-- as an `sts.java.*` command, which jdtls understands once the extension's
-- bundles are loaded into it. jdtls reports classpath changes back through
-- `workspace/executeClientCommand` with a callback id the Spring server chose,
-- which we hand back to the Spring server. This file is that bridge.
local config = require("sprout.config")
local jdk = require("sprout.jdk")
local project = require("sprout.project")

local M = {}

local function mason(path)
  return (vim.env.MASON or (vim.fn.stdpath("data") .. "/mason")) .. "/" .. path
end

function M.jar()
  local jar = mason("share/vscode-spring-boot-tools/language-server.jar")
  if vim.uv.fs_stat(jar) then
    return jar
  end
  return vim.fn.glob(mason("packages/vscode-spring-boot-tools/extension/language-server/*language-server*.jar"), false, true)[1]
end

--- Extension bundles jdtls must load for the `sts.java.*` commands: the
--- `javaExtensions` of the VS Code extension's package.json. The other jars in
--- that folder aren't OSGi bundles, and jdtls complains about them.
function M.bundles()
  local ext = mason("packages/vscode-spring-boot-tools/extension")
  local ok, manifest = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(ext .. "/package.json"), "\n"))
  end)
  local list = ok and manifest.contributes and manifest.contributes.javaExtensions or {}
  local out = {}
  for _, rel in ipairs(list) do
    local path = vim.fs.normalize(ext .. "/" .. rel)
    if vim.uv.fs_stat(path) then
      out[#out + 1] = path
    end
  end
  return out
end

function M.wanted(root)
  return config.spring_ls.enabled and root ~= nil and M.jar() ~= nil and project.is_boot(root)
end

-- The server keys features off VS Code language ids, not Neovim filetypes.
local LANGUAGE_IDS = {
  java = "java",
  yaml = "spring-boot-properties-yaml",
  jproperties = "spring-boot-properties",
}

--- application.yml / bootstrap-dev.properties / …: the only yaml/properties it should see.
local function is_boot_config(name)
  local base = vim.fs.basename(name)
  return base:match("^application.*%.ya?ml$")
    or base:match("^application.*%.properties$")
    or base:match("^bootstrap.*%.ya?ml$")
    or base:match("^bootstrap.*%.properties$")
end

local ready = {} ---@type table<string, boolean> jdtls root → ServiceReady seen

local function jdtls_for(root)
  for _, c in ipairs(vim.lsp.get_clients({ name = "jdtls" })) do
    if c.root_dir == root and c.initialized then
      return c
    end
  end
end

--- Record jdtls' ServiceReady per root (nvim-jdtls calls this handler without
--- a ctx), keeping the default behaviour of echoing the status line.
function M.track_ready(cfg)
  local root = cfg.root_dir
  cfg.handlers = cfg.handlers or {}
  local inner = cfg.handlers["language/status"]
  cfg.handlers["language/status"] = function(err, result, ...)
    if root and result and result.type == "ServiceReady" then
      ready[root] = true
    end
    if inner then
      return inner(err, result, ...)
    end
    if result and result.message then
      vim.api.nvim_echo({ { result.message:sub(1, vim.v.echospace), "Function" } }, false, {})
    end
  end
  return cfg
end

--- Forward one `sts/*` request to jdtls.
---
--- Must not block: jdtls often calls back into Neovim (the classpath
--- callback) before answering, so waiting with request_sync deadlocks both.
--- Neovim runs server-request handlers inside a coroutine, so yield until
--- jdtls responds and answer the Spring server then.
local function forward(command, args_of)
  return function(_, params, ctx)
    local client = vim.lsp.get_client_by_id(ctx.client_id)
    local jdtls = client and jdtls_for(client.root_dir)
    if not jdtls then
      return nil, vim.lsp.rpc_response_error(vim.lsp.protocol.ErrorCodes.InternalError, "jdtls isn't running yet")
    end
    local co, main = coroutine.running()
    assert(co and not main, "sprout: server request handler not running in a coroutine")
    jdtls:request("workspace/executeCommand", { command = command, arguments = args_of(params) }, function(err, result)
      coroutine.resume(co, err, result)
    end)
    local err, result = coroutine.yield()
    if err then
      return nil, vim.lsp.rpc_response_error(err.code or vim.lsp.protocol.ErrorCodes.InternalError, err.message)
    end
    return result == nil and vim.NIL or result
  end
end

local function whole(params)
  return { params }
end

local handlers = {
  ["sts/javaType"] = forward("sts.java.type", whole),
  ["sts/javadocHoverLink"] = forward("sts.java.javadocHoverLink", whole),
  ["sts/javaLocation"] = forward("sts.java.location", whole),
  ["sts/javadoc"] = forward("sts.java.javadoc", whole),
  ["sts/javaSearchTypes"] = forward("sts.java.search.types", whole),
  ["sts/javaSearchPackages"] = forward("sts.java.search.packages", whole),
  ["sts/javaSubTypes"] = forward("sts.java.hierarchy.subtypes", whole),
  ["sts/javaSuperTypes"] = forward("sts.java.hierarchy.supertypes", whole),
  ["sts/javaCodeComplete"] = forward("sts.java.code.completions", whole),
  ["sts/project/gav"] = forward("sts.project.gav", whole),
  ["sts/removeClasspathListener"] = forward("sts.java.removeClasspathListener", function(p)
    return { p.callbackCommandId }
  end),
  -- Highlights for live-running apps (Spring Boot Actuator); nothing to draw.
  ["sts/highlight"] = function()
    return vim.NIL
  end,
}

local add_listener = forward("sts.java.addClasspathListener", function(p)
  return { p.callbackCommandId }
end)

handlers["sts/addClasspathListener"] = function(err, params, ctx)
  local spring_id = ctx.client_id
  -- jdtls calls this id back (workspace/executeClientCommand, which
  -- nvim-jdtls routes through vim.lsp.commands) whenever a classpath changes.
  vim.lsp.commands[params.callbackCommandId] = function(args)
    local spring = vim.lsp.get_client_by_id(spring_id)
    if spring then
      spring:request("workspace/executeCommand", { command = params.callbackCommandId, arguments = args }, function() end)
    end
    return vim.NIL
  end
  return add_listener(err, params, ctx)
end

--- Wait until jdtls on the same root has imported the project (ServiceReady),
--- then let the Spring server start listening. Earlier, the listener request
--- sits behind the import and the Spring server times it out after 10s.
local function enable_classpath(client)
  local tries = 0
  local function try()
    if client:is_stopped() then
      return
    end
    if ready[client.root_dir] and jdtls_for(client.root_dir) then
      client:request("workspace/executeCommand", {
        command = "sts.vscode-spring-boot.enableClasspathListening",
        arguments = { true },
      }, function() end)
      return
    end
    tries = tries + 1
    if tries < 600 then -- 10 min: jdtls only starts once a Java file is opened
      vim.defer_fn(try, 1000)
    end
  end
  try()
end

function M.cmd()
  local java = jdk.find(config.spring_ls.java, true)
  local cmd = { java and (java.home .. "/bin/java") or "java" }
  vim.list_extend(cmd, config.spring_ls.jvm_args or {})
  vim.list_extend(cmd, {
    "-Dsts.lsp.client=vscode",
    "-Dspring.config.location=classpath:/application.properties",
    "-Djdk.util.zip.disableZip64ExtraFieldValidation=true",
    "-Dspring.main.web-application-type=NONE",
    "-Xlog:jni+resolve=off",
    "-jar",
    M.jar(),
  })
  return cmd
end

local starting = {} ---@type table<string, boolean>

--- The Spring server gets its classpath from jdtls, and jdtls normally starts
--- with the first Java buffer. When application.yml is opened first, start it
--- from a hidden buffer holding the @SpringBootApplication class. The buffer is
--- made current while its filetype is set, so whatever starts jdtls (LazyVim's
--- java extra, or sprout's own autocmd) attaches it and not the YAML buffer.
local function ensure_jdtls(root)
  if starting[root] then
    return
  end
  for _, c in ipairs(vim.lsp.get_clients({ name = "jdtls" })) do
    if c.root_dir == root then
      return
    end
  end
  starting[root] = true
  local function first(args)
    local res = vim.system(vim.list_extend({ "rg", "--glob", "*.java", "--glob", "!**/build/**", "--glob", "!**/target/**" }, args), { text = true }):wait()
    return (res.stdout or ""):match("[^\n]+")
  end
  local file = first({ "--files-with-matches", "--max-count", "1", "@SpringBootApplication", root })
    or first({ "--files", root })
  if not file then
    return
  end
  local buf = vim.fn.bufadd(file)
  vim.bo[buf].buflisted = false
  vim.api.nvim_buf_call(buf, function()
    vim.fn.bufload(buf)
    if vim.bo[buf].filetype ~= "java" then
      vim.bo[buf].filetype = "java"
    end
  end)
end

---@param bufnr integer
function M.attach(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  local ft = vim.bo[bufnr].filetype
  if name == "" or not LANGUAGE_IDS[ft] or (ft ~= "java" and not is_boot_config(name)) then
    return
  end
  local root = project.root(name)
  if not M.wanted(root) then
    return
  end
  local ok, blink = pcall(require, "blink.cmp")
  local capabilities = vim.tbl_deep_extend(
    "force",
    ok and blink.get_lsp_capabilities() or vim.lsp.protocol.make_client_capabilities(),
    -- The server registers its commands dynamically and crashes in
    -- initialize (NPE on ExecuteCommandOptions) if the client can't take them.
    { workspace = { executeCommand = { dynamicRegistration = true } } }
  )
  vim.lsp.start({
    name = "spring_boot",
    cmd = M.cmd(),
    root_dir = root,
    workspace_folders = { { uri = vim.uri_from_fname(root), name = vim.fs.basename(root) } },
    init_options = { workspaceFolders = { vim.uri_from_fname(root) }, enableJdtClasspath = false },
    capabilities = capabilities,
    get_language_id = function(_, filetype)
      return LANGUAGE_IDS[filetype] or filetype
    end,
    handlers = handlers,
    on_init = enable_classpath,
  }, { bufnr = bufnr })
  if ft ~= "java" then
    vim.schedule(function()
      ensure_jdtls(root)
    end)
  end
end

function M.setup()
  if not config.spring_ls.enabled then
    return
  end
  local group = vim.api.nvim_create_augroup("sprout.spring_ls", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = vim.tbl_keys(LANGUAGE_IDS),
    callback = function(ev)
      M.attach(ev.buf)
    end,
  })
  -- Buffers that were already open when sprout loaded.
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      M.attach(buf)
    end
  end
end

return M
