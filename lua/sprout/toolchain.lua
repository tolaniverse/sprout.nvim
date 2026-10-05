-- Kotlin Toolchain (`kotlin init`, formerly Amper) projects have no Gradle or
-- Maven build jdtls could import, so jdtls treats them as an unmanaged folder.
-- This gives it what an import would: each module's source folders, and the
-- dependency jars, resolved by `kotlin show dependencies` and found in the
-- toolchain's Maven-layout cache.
local M = {}

local uv = vim.uv

---@class sprout.ToolchainClasspath
---@field jars string[]
---@field missing integer coordinates without a jar in the caches (BOMs, metadata-only artifacts)
---@field stamp integer newest module.yaml/project.yaml mtime it was resolved for

---@type table<string, sprout.ToolchainClasspath>
local memo = {}
---@type table<string, boolean>
local running = {}

--- The toolchain's shared cache (`kotlin --shared-cache-dir`'s default).
function M.cache_dir()
  local configured = require("sprout.config").kotlin_toolchain.cache_dir
  if configured then
    return vim.fn.expand(configured)
  end
  local sys = uv.os_uname().sysname
  if sys == "Darwin" then
    return vim.fn.expand("~/Library/Caches/JetBrains/Kotlin")
  elseif sys:find("Windows") then
    return (vim.env.LOCALAPPDATA or vim.fn.expand("~/AppData/Local")) .. "/JetBrains/Kotlin"
  end
  return (vim.env.XDG_CACHE_HOME or vim.fn.expand("~/.cache")) .. "/JetBrains/Kotlin"
end

--- Directories (relative to the root, "" for the root) that hold a module.yaml.
function M.modules(root)
  local out = {}
  if uv.fs_stat(root .. "/module.yaml") then
    out[1] = ""
  end
  for _, pattern in ipairs({ "/*/module.yaml", "/*/*/module.yaml" }) do
    for _, f in ipairs(vim.fn.glob(root .. pattern, false, true)) do
      local dir = vim.fs.dirname(f):sub(#root + 2)
      if not dir:match("^build/") then
        out[#out + 1] = dir
      end
    end
  end
  return out
end

--- Source folders for jdtls, relative to the root.
function M.source_paths(root)
  local out = {}
  for _, dir in ipairs(M.modules(root)) do
    for _, sub in ipairs({ "src", "test" }) do
      local rel = dir == "" and sub or (dir .. "/" .. sub)
      if uv.fs_stat(root .. "/" .. rel) then
        out[#out + 1] = rel
      end
    end
  end
  return out
end

--- `group:artifact:version` (with conflict resolution: `… -> 2.3.21`) from
--- `kotlin show dependencies`' trees. Module nodes (`mod:main:g:a:v`) repeat
--- their child, so only plain coordinates are taken.
---@return string[]
function M.parse(text)
  local seen, out = {}, {}
  for line in text:gmatch("[^\n]+") do
    local coord = line:match("─── (%S+)")
    if coord then
      local resolved = line:match(" %-> ([^%s,]+)")
      local parts = vim.split(coord:gsub(",$", ""), ":", { plain = true })
      if #parts == 3 then
        local id = ("%s:%s:%s"):format(parts[1], parts[2], resolved or parts[3])
        if not seen[id] then
          seen[id] = true
          out[#out + 1] = id
        end
      end
    end
  end
  return out
end

--- The jar for a coordinate, in the toolchain's cache or ~/.m2.
function M.jar(coord)
  local g, a, v = coord:match("^([^:]+):([^:]+):([^:]+)$")
  if not g then
    return nil
  end
  local rel = ("%s/%s/%s/%s-%s.jar"):format(g:gsub("%.", "/"), a, v, a, v)
  for _, repo in ipairs({ M.cache_dir() .. "/.m2.cache", vim.fn.expand("~/.m2/repository") }) do
    local path = repo .. "/" .. rel
    if uv.fs_stat(path) then
      return path
    end
  end
end

--- Newest mtime of the files that decide the dependencies.
local function stamp(root)
  local newest = 0
  local files = { root .. "/project.yaml" }
  for _, dir in ipairs(M.modules(root)) do
    files[#files + 1] = root .. "/" .. (dir == "" and "" or dir .. "/") .. "module.yaml"
  end
  for _, f in ipairs(files) do
    local st = uv.fs_stat(f)
    if st and st.mtime.sec > newest then
      newest = st.mtime.sec
    end
  end
  return newest
end

local function cache_file(root)
  return vim.fn.stdpath("cache") .. "/sprout/toolchain/" .. vim.fn.sha256(root):sub(1, 16) .. ".json"
end

local function load(root)
  if memo[root] then
    return memo[root]
  end
  local fd = io.open(cache_file(root), "r")
  if not fd then
    return nil
  end
  local ok, data = pcall(vim.json.decode, fd:read("*a"))
  fd:close()
  if ok and type(data) == "table" and type(data.jars) == "table" then
    memo[root] = data
    return data
  end
end

local function save(root, data)
  memo[root] = data
  local path = cache_file(root)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local fd = io.open(path, "w")
  if fd then
    fd:write(vim.json.encode(data))
    fd:close()
  end
end

--- Jars the last resolution found, plus each module's own jar from a previous
--- `kotlin build`/`run`, so Java code sees the project's Kotlin classes.
---@return string[]? nil until dependencies were resolved once
function M.libraries(root)
  local data = load(root)
  if not data then
    return nil
  end
  local out = vim.list_slice(data.jars)
  vim.list_extend(out, vim.fn.glob(root .. "/build/tasks/_*_jarJvm/*.jar", false, true))
  return out
end

--- Whether the saved classpath predates a module.yaml/project.yaml change.
function M.stale(root)
  local data = load(root)
  return not data or (data.stamp or 0) < stamp(root)
end

--- Resolve dependencies with `kotlin show dependencies` in the background.
---@param on_done? fun(data: sprout.ToolchainClasspath?, err: string?)
function M.resolve(root, on_done)
  local p = require("sprout.project").get(root)
  if not p or p.tool ~= "kotlin" or running[root] then
    return
  end
  running[root] = true
  local started = stamp(root)
  vim.system(
    { p.exe, "show", "dependencies", "--all-modules", "--include-tests" },
    { cwd = root, text = true, stdin = false },
    vim.schedule_wrap(function(res)
      running[root] = nil
      if res.code ~= 0 then
        local err = vim.trim((res.stderr or "") .. "\n" .. (res.stdout or "")):sub(-500)
        return on_done and on_done(nil, err)
      end
      local jars, missing = {}, 0
      for _, coord in ipairs(M.parse(res.stdout or "")) do
        local jar = M.jar(coord)
        if jar then
          jars[#jars + 1] = jar
        else
          missing = missing + 1
        end
      end
      local data = { jars = jars, missing = missing, stamp = started }
      save(root, data)
      if on_done then
        on_done(data)
      end
    end)
  )
end

--- jdtls settings for an unmanaged Kotlin Toolchain folder.
function M.jdtls_settings(root)
  return {
    java = {
      project = {
        sourcePaths = M.source_paths(root),
        referencedLibraries = M.libraries(root) or {},
        -- JDT's own compile output; inside build/, which the toolchain owns.
        outputPath = "build/jdtls",
      },
    },
  }
end

local function libs_of(client)
  return vim.tbl_get(client.settings or {}, "java", "project", "referencedLibraries") or {}
end

--- Send fresh settings to one jdtls client. jdtls only re-reads
--- referencedLibraries when they differ from what it has, so `reset` clears
--- them first to make it re-apply an unchanged list.
local function push_to(client, root, reset)
  local settings = require("sprout.jdtls").settings(root, client.settings)
  if reset then
    local empty = vim.deepcopy(settings)
    empty.java.project.referencedLibraries = {}
    client:notify("workspace/didChangeConfiguration", { settings = empty })
  end
  client.settings = settings
  client:notify("workspace/didChangeConfiguration", { settings = settings })
end

--- Push fresh settings to jdtls clients of this root. Clients still starting
--- get them in the LspAttach handler below.
local function push(root, reset)
  for _, client in ipairs(vim.lsp.get_clients({ name = "jdtls" })) do
    if client.root_dir == root and client.initialized then
      push_to(client, root, reset)
    end
  end
end

-- A resolution can finish before jdtls is up (or jdtls can start with an
-- older saved classpath); bring it up to date once it attaches.
vim.api.nvim_create_autocmd("LspAttach", {
  group = vim.api.nvim_create_augroup("sprout.toolchain", { clear = true }),
  callback = function(ev)
    local client = vim.lsp.get_client_by_id(ev.data.client_id)
    local root = client and client.name == "jdtls" and client.root_dir
    local p = root and require("sprout.project").get(root)
    local libs = p and p.tool == "kotlin" and M.libraries(root)
    if libs and not vim.deep_equal(libs, libs_of(client)) then
      push_to(client, root)
    end
  end,
})

--- Resolve (if stale) and hand the result to running jdtls clients.
---@param force? boolean resolve even when the saved classpath is current
function M.refresh(root, force)
  if not force and not M.stale(root) then
    return
  end
  if running[root] then
    return
  end
  vim.notify(("sprout: resolving %s dependencies…"):format(vim.fs.basename(root)))
  M.resolve(root, function(data, err)
    if not data then
      return vim.notify("sprout: `kotlin show dependencies` failed:\n" .. (err or ""), vim.log.levels.WARN)
    end
    push(root, force)
    vim.notify(("sprout: %s classpath updated (%d jars)"):format(vim.fs.basename(root), #data.jars))
  end)
end

return M
