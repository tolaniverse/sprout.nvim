-- Project detection: which directory is the build root and which tool owns it.
local M = {}

local uv = vim.uv

local function exists(path)
  return uv.fs_stat(path) ~= nil
end

--- The nearest of several candidate roots wins (longest path).
local function nearest(...)
  local best
  for _, dir in pairs({ ... }) do
    if dir and (not best or #dir > #best) then
      best = dir
    end
  end
  return best
end

--- Maven multi-module builds nest poms; the build root is the topmost pom in
--- an unbroken chain of parents that have one.
local function maven_root(path)
  local dir = vim.fs.root(path, "pom.xml")
  if not dir then
    return nil
  end
  while true do
    local parent = vim.fs.dirname(dir)
    if parent == dir or not exists(parent .. "/pom.xml") then
      return dir
    end
    dir = parent
  end
end

---@param path? string file or directory; defaults to the current buffer
---@return string?
function M.root(path)
  path = path or vim.api.nvim_buf_get_name(0)
  if path == "" then
    path = uv.cwd()
  end
  -- An explicit `.idea/sprout.json` pins the root, e.g. for a monorepo.
  local pinned = vim.fs.root(path, ".idea/sprout.json")
  if pinned then
    return pinned
  end
  local gradle = vim.fs.root(path, { "settings.gradle", "settings.gradle.kts", "gradlew" })
    or vim.fs.root(path, { "build.gradle", "build.gradle.kts" })
  local maven = vim.fs.root(path, "mvnw") or maven_root(path)
  local bleep = vim.fs.root(path, "bleep.yaml")
  return nearest(gradle, maven, bleep)
end

---@alias sprout.Tool "gradle"|"maven"|"bleep"

---@class sprout.Project
---@field root string
---@field name string
---@field tool sprout.Tool
---@field exe string build command (wrapper when present)

---@param root string
---@return sprout.Project?
function M.get(root)
  if not root then
    return nil
  end
  local function has(f)
    return exists(root .. "/" .. f)
  end
  local p = { root = root, name = vim.fs.basename(root) }
  if has("bleep.yaml") then
    p.tool, p.exe = "bleep", "bleep"
  elseif has("pom.xml") or has("mvnw") then
    p.tool, p.exe = "maven", has("mvnw") and root .. "/mvnw" or "mvn"
  else
    p.tool, p.exe = "gradle", has("gradlew") and root .. "/gradlew" or "gradle"
  end
  return p
end

local uses_cache = {} ---@type table<string, boolean>

--- Whether any build file in the project (3 levels deep) mentions `needle`.
function M.uses(root, needle)
  local key = root .. "\0" .. needle
  if uses_cache[key] == nil then
    local res = vim.system({
      "rg", "--quiet", "--max-depth", "3", "--fixed-strings", needle,
      "--glob", "{pom.xml,build.gradle,build.gradle.kts,libs.versions.toml,bleep.yaml}", root,
    }):wait()
    uses_cache[key] = res.code == 0
  end
  return uses_cache[key]
end

--- Whether the project uses Spring Boot.
function M.is_boot(root)
  return M.uses(root, "org.springframework.boot")
end

--- Whether the project uses Ktor (server or client).
function M.is_ktor(root)
  return M.uses(root, "io.ktor")
end

local kotlin = {} ---@type table<string, boolean>

--- Whether the project has Kotlin sources.
function M.has_kotlin(root)
  if kotlin[root] == nil then
    local res = vim.system({
      "rg", "--files", "--max-count", "1", "--glob", "*.kt",
      "--glob", "!**/build/**", "--glob", "!**/target/**", "--glob", "!**/.bleep/**", root,
    }, { text = true }):wait()
    kotlin[root] = (res.stdout or "") ~= ""
  end
  return kotlin[root]
end

--- Forget cached build facts, e.g. after a build file changed.
function M.invalidate(root)
  kotlin[root] = nil
  for key in pairs(uses_cache) do
    if key:sub(1, #root + 1) == root .. "\0" then
      uses_cache[key] = nil
    end
  end
end

---@class sprout.Main
---@field class string fully qualified name
---@field dir string module directory relative to the root ("" for the root module)

--- The package and, for Kotlin, an `@file:JvmName` from a source file's header.
local function header_of(file)
  local fd = io.open(file, "r")
  if not fd then
    return nil
  end
  local pkg, jvm_name
  for _ = 1, 100 do
    local line = fd:read("*l")
    if not line then
      break
    end
    jvm_name = jvm_name or line:match('^%s*@file:JvmName%(%s*"([^"]+)"')
    pkg = line:match("^%s*package%s+([%w_%.]+)")
    if pkg then
      break
    end
  end
  fd:close()
  return pkg, jvm_name
end

--- Classes with a `main` method outside test sources: Java `static void main(`
--- and Kotlin top-level `fun main(` / `suspend fun main(`.
---@return sprout.Main[]
function M.mains(root)
  local res = vim.system({
    "rg", "--files-with-matches", "--no-messages",
    "--glob", "*.java", "--glob", "*.kt",
    "--glob", "!**/src/test/**", "--glob", "!**/build/**", "--glob", "!**/target/**",
    "--glob", "!**/node_modules/**", "--glob", "!**/.bleep/**",
    "-e", [[static\s+void\s+main\s*\(]], "-e", [[^(suspend\s+)?fun\s+main\s*\(]],
    root,
  }, { text = true }):wait()
  local out = {}
  for file in (res.stdout or ""):gmatch("[^\n]+") do
    local name, ext = vim.fs.basename(file):match("^(.+)%.(%w+)$")
    local pkg, jvm_name = header_of(file)
    if ext == "kt" then
      -- The class Kotlin generates for top-level functions.
      name = jvm_name or (name:sub(1, 1):upper() .. name:sub(2) .. "Kt")
    end
    local rel = file:sub(#root + 2)
    out[#out + 1] = {
      class = pkg and (pkg .. "." .. name) or name,
      dir = rel:match("^(.-)/?src/") or "",
    }
  end
  table.sort(out, function(a, b)
    return a.class < b.class
  end)
  return out
end

---@return sprout.Project?
function M.current()
  return M.get(M.root())
end

vim.api.nvim_create_autocmd("BufWritePost", {
  group = vim.api.nvim_create_augroup("sprout.project", { clear = true }),
  pattern = { "pom.xml", "*.gradle", "*.gradle.kts", "libs.versions.toml", "bleep.yaml" },
  callback = function(ev)
    local root = M.root(ev.file)
    if root then
      M.invalidate(root)
    end
  end,
})

return M
