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

local boot = {} ---@type table<string, boolean>

--- Whether any build file in the project (3 levels deep) uses Spring Boot.
function M.is_boot(root)
  if boot[root] == nil then
    local res = vim.system({
      "rg", "--quiet", "--max-depth", "3", "--fixed-strings", "org.springframework.boot",
      "--glob", "{pom.xml,build.gradle,build.gradle.kts,libs.versions.toml,bleep.yaml}", root,
    }):wait()
    boot[root] = res.code == 0
  end
  return boot[root]
end

---@return sprout.Project?
function M.current()
  return M.get(M.root())
end

return M
