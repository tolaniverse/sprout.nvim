-- JDK discovery (SDKMAN first) and per-project JDK resolution.
local config = require("sprout.config")
local idea = require("sprout.idea")

local M = {}

local uv = vim.uv

---@class sprout.Jdk
---@field home string
---@field major integer
---@field version string
---@field id string  SDKMAN candidate id or directory name

local function read(path)
  local fd = io.open(path, "r")
  if not fd then
    return nil
  end
  local s = fd:read("*a")
  fd:close()
  return s
end

---@return sprout.Jdk?
local function probe(home, id)
  home = uv.fs_realpath(home)
  local release = home and read(home .. "/release")
  local version = release and release:match('JAVA_VERSION="([^"]+)"')
  if not version then
    return nil
  end
  local major = tonumber(version:match("^1%.(%d+)") or version:match("^(%d+)"))
  return { home = home, major = major, version = version, id = id or vim.fs.basename(home) }
end

local jdks ---@type sprout.Jdk[]?

local function dir(path)
  return uv.fs_stat(path) and vim.fs.dir(path) or function() end
end

local function version_lt(a, b)
  local ok, lt = pcall(vim.version.lt, (a:gsub("[^%d%.].*", "")), (b:gsub("[^%d%.].*", "")))
  return ok and lt
end

--- Every JDK on the machine, newest first. Scanned once per session.
---@return sprout.Jdk[]
function M.list()
  if jdks then
    return jdks
  end
  local found, seen = {}, {}
  local function add(home, id)
    local j = probe(home, id)
    if j and not seen[j.home] then
      seen[j.home] = true
      found[#found + 1] = j
    end
  end
  local sdkman = vim.env.SDKMAN_DIR or vim.fn.expand("~/.sdkman")
  for name, kind in dir(sdkman .. "/candidates/java") do
    if name ~= "current" and kind ~= "link" then
      add(sdkman .. "/candidates/java/" .. name, name)
    end
  end
  for name in dir("/Library/Java/JavaVirtualMachines") do
    add("/Library/Java/JavaVirtualMachines/" .. name .. "/Contents/Home")
  end
  for name in dir("/usr/lib/jvm") do
    add("/usr/lib/jvm/" .. name)
  end
  for _, home in ipairs(config.jdks or {}) do
    add(vim.fn.expand(home))
  end
  if vim.env.JAVA_HOME then
    add(vim.env.JAVA_HOME)
  end
  table.sort(found, function(a, b)
    if a.major ~= b.major then
      return a.major > b.major
    end
    return version_lt(b.version, a.version)
  end)
  jdks = found
  return found
end

---@param major integer
---@param at_least? boolean accept a newer major if the exact one is missing
---@return sprout.Jdk?
function M.find(major, at_least)
  local best
  for _, j in ipairs(M.list()) do
    if j.major == major then
      return j
    elseif at_least and j.major > major then
      best = j -- list is newest-first, so the last hit is the closest newer one
    end
  end
  return best
end

--- "21", "21.0.11-amzn", "corretto-21", "/path/to/home" → a JDK.
---@return sprout.Jdk?
function M.from_spec(spec)
  if spec == nil then
    return nil
  end
  spec = tostring(spec)
  if spec:find("/") then
    return probe(vim.fn.expand(spec))
  end
  for _, j in ipairs(M.list()) do
    if j.id == spec then
      return j
    end
  end
  local major = tonumber(spec:match("^1%.(%d+)$") or spec:match("^(%d+)$") or spec:match("(%d+)"))
  return major and M.find(major, true)
end

--- "17" → 17, "1.8" → 8, "'21'" → 21
local function major_of(v)
  v = v and v:match("[%d%.]+")
  return v and tonumber(v:match("^1%.(%d+)") or v:match("^(%d+)"))
end

local function build_file_major(root)
  local gradle = read(root .. "/build.gradle.kts") or read(root .. "/build.gradle")
  if gradle then
    local v = gradle:match("JavaLanguageVersion%.of%(%s*([%d%.]+)")
      or gradle:match("jvmToolchain%(%s*([%d%.]+)")
      or gradle:match("JavaVersion%.VERSION_([%d_]+)")
      or gradle:match("JvmTarget%.JVM_([%d_]+)")
      or gradle:match("sourceCompatibility%s*=%s*['\"]?([%d%.]+)")
      or gradle:match("jvmTarget%s*=%s*['\"]([%d%.]+)")
    if v then
      return major_of(v:gsub("_", "."))
    end
  end
  local pom = read(root .. "/pom.xml")
  if pom then
    return major_of(
      pom:match("<java%.version>%s*([%d%.]+)")
        or pom:match("<maven%.compiler%.release>%s*([%d%.]+)")
        or pom:match("<release>%s*([%d%.]+)%s*</release>")
        or pom:match("<maven%.compiler%.source>%s*([%d%.]+)")
        or pom:match("<kotlin%.compiler%.jvmTarget>%s*([%d%.]+)")
        or pom:match("<jvmTarget>%s*([%d%.]+)%s*</jvmTarget>")
    )
  end
end

---@class sprout.ResolvedJdk: sprout.Jdk
---@field source string where the choice came from

--- The JDK a project builds and runs with. First match wins:
--- .idea/sprout.json → .sdkmanrc → .idea/misc.xml → build file → SDKMAN current.
---@return sprout.ResolvedJdk?
function M.resolve(root)
  local function tag(j, source)
    if j then
      return vim.tbl_extend("force", j, { source = source })
    end
  end
  local j = tag(M.from_spec(idea.settings(root).jdk), ".idea/sprout.json")
  if j then
    return j
  end
  local rc = read(root .. "/.sdkmanrc")
  j = rc and tag(M.from_spec(rc:match("java%s*=%s*([^%s]+)")), ".sdkmanrc")
  if j then
    return j
  end
  local misc = idea.misc(root)
  if misc then
    j = tag(M.from_spec(misc.jdk_name) or (misc.language_level and M.find(misc.language_level, true)), ".idea/misc.xml")
    if j then
      return j
    end
  end
  local major = build_file_major(root)
  j = major and tag(M.find(major, true), "build file (Java " .. major .. ")")
  if j then
    return j
  end
  local sdkman = vim.env.SDKMAN_DIR or vim.fn.expand("~/.sdkman")
  return tag(probe(sdkman .. "/candidates/java/current") or probe(vim.env.JAVA_HOME or ""), "default")
end

--- jdtls' name for an execution environment.
function M.runtime_name(major)
  return major <= 8 and ("JavaSE-1." .. major) or ("JavaSE-" .. major)
end

--- One runtime per major version, with the project's marked default.
function M.runtimes(project_jdk)
  local out, seen = {}, {}
  for _, j in ipairs(M.list()) do
    if not seen[j.major] then
      seen[j.major] = true
      local pick = (project_jdk and project_jdk.major == j.major) and project_jdk or j
      out[#out + 1] = {
        name = M.runtime_name(j.major),
        path = pick.home,
        default = project_jdk ~= nil and project_jdk.major == j.major or nil,
      }
    end
  end
  return out
end

return M
