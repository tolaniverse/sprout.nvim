-- Everything sprout knows about a project lives in `.idea/`: its own
-- `.idea/sprout.json`, plus whatever IntelliJ already wrote there (project JDK
-- in misc.xml, Spring Boot / Application run configurations). Nothing else is
-- ever written into the project.
local M = {}

local uv = vim.uv

-- Parsed files keyed by path, invalidated by mtime.
local cache = {}

local function cached(path, parse)
  local stat = uv.fs_stat(path)
  if not stat then
    cache[path] = nil
    return nil
  end
  local hit = cache[path]
  if hit and hit.mtime == stat.mtime.sec and hit.size == stat.size then
    return hit.value
  end
  local fd = io.open(path, "r")
  if not fd then
    return nil
  end
  local text = fd:read("*a")
  fd:close()
  local ok, value = pcall(parse, text)
  if not ok then
    vim.notify(("sprout: can't parse %s: %s"):format(path, value), vim.log.levels.WARN)
    value = nil
  end
  cache[path] = { mtime = stat.mtime.sec, size = stat.size, value = value }
  return value
end

---@class sprout.Settings
---@field jdk? string|integer   major ("21"), SDKMAN id ("21.0.11-amzn") or a JDK home path
---@field profiles? string[]
---@field env? table<string,string>
---@field envFile? string       relative to the root
---@field vmArgs? string[]
---@field args? string[]
---@field module? string        Gradle subproject (":api") / Maven module ("api") / bleep project
---@field jdtls? table          extra jdtls `settings`

---@return sprout.Settings
function M.settings(root)
  return cached(root .. "/.idea/sprout.json", function(text)
    return vim.json.decode(text, { luanil = { object = true, array = true } })
  end) or {}
end

function M.write_settings(root, tbl)
  vim.fn.mkdir(root .. "/.idea", "p")
  local path = root .. "/.idea/sprout.json"
  local ok, json = pcall(vim.json.encode, tbl)
  if not ok then
    return vim.notify("sprout: " .. json, vim.log.levels.ERROR)
  end
  -- jq pretty-prints when available; the file is meant to be hand-edited.
  if vim.fn.executable("jq") == 1 then
    local out = vim.system({ "jq", "." }, { stdin = json }):wait()
    if out.code == 0 then
      json = out.stdout
    end
  end
  local fd = assert(io.open(path, "w"))
  fd:write(json)
  fd:close()
  return path
end

local entities = { quot = '"', amp = "&", lt = "<", gt = ">", apos = "'" }

local function unescape(s)
  return (
    s:gsub("&(#?x?)(%w+);", function(kind, v)
      if kind == "#" then
        return vim.fn.nr2char(tonumber(v))
      elseif kind == "#x" then
        return vim.fn.nr2char(tonumber(v, 16))
      end
      return entities[v]
    end)
  )
end

local function attrs(tag)
  local t = {}
  for k, v in tag:gmatch('([%w_%-]+)="([^"]*)"') do
    t[k] = unescape(v)
  end
  return t
end

--- IntelliJ's project JDK: `<component name="ProjectRootManager" project-jdk-name="21" languageLevel="JDK_21">`
---@return {jdk_name?: string, language_level?: integer}?
function M.misc(root)
  return cached(root .. "/.idea/misc.xml", function(text)
    local tag = text:match("<component[^>]-ProjectRootManager[^>]*>")
    if not tag then
      return nil
    end
    local a = attrs(tag)
    local level = a.languageLevel and a.languageLevel:match("JDK_1?_?(%d+)")
    return { jdk_name = a["project-jdk-name"], language_level = tonumber(level) }
  end)
end

---@class sprout.RunConfig
---@field name string
---@field main? string
---@field profiles? string[]
---@field vmArgs? string[]
---@field args? string[]
---@field env? table<string,string>
---@field module? string

--- Split a command line the way IntelliJ does: whitespace, honouring quotes.
local function shell_split(s)
  if not s or s == "" then
    return nil
  end
  local out, cur, quote, has = {}, {}, nil, false
  for ch in s:gmatch(".") do
    if quote then
      if ch == quote then
        quote = nil
      else
        cur[#cur + 1] = ch
      end
    elseif ch == '"' or ch == "'" then
      quote, has = ch, true
    elseif ch:match("%s") then
      if #cur > 0 or has then
        out[#out + 1] = table.concat(cur)
      end
      cur, has = {}, false
    else
      cur[#cur + 1] = ch
    end
  end
  if #cur > 0 or has then
    out[#out + 1] = table.concat(cur)
  end
  return out
end

local run_types = {
  SpringBootApplicationConfigurationType = true,
  Application = true,
  JetRunConfigurationType = true, -- Kotlin
}

local function parse_run_configs(text)
  local out = {}
  for open, body in text:gmatch("(<configuration%s[^>]->)(.-)</configuration>") do
    local a = attrs(open)
    if run_types[a.type] and a.name and a.temporary ~= "true" then
      local opt = {}
      for tag in body:gmatch("<option%s[^>]-/>") do
        local o = attrs(tag)
        if o.name then
          opt[o.name] = o.value
        end
      end
      local env = {}
      for tag in body:gmatch("<env%s[^>]-/>") do
        local e = attrs(tag)
        if e.name then
          env[e.name] = e.value or ""
        end
      end
      local module = body:match('<module name="([^"]*)"')
      local profiles = opt.ACTIVE_PROFILES
      out[#out + 1] = {
        name = a.name,
        main = opt.SPRING_BOOT_MAIN_CLASS or opt.MAIN_CLASS_NAME,
        profiles = profiles and profiles ~= "" and vim.split(profiles, "%s*,%s*") or nil,
        vmArgs = shell_split(opt.VM_PARAMETERS),
        args = shell_split(opt.PROGRAM_PARAMETERS),
        env = next(env) and env or nil,
        module = module,
      }
    end
  end
  return out
end

--- Run configurations IntelliJ saved, shared (.idea/runConfigurations) or
--- local (.idea/workspace.xml).
---@return sprout.RunConfig[]
function M.run_configs(root)
  local out, seen = {}, {}
  local files = vim.fn.glob(root .. "/.idea/runConfigurations/*.xml", false, true)
  table.insert(files, root .. "/.idea/workspace.xml")
  for _, f in ipairs(files) do
    for _, rc in ipairs(cached(f, parse_run_configs) or {}) do
      if not seen[rc.name] then
        seen[rc.name] = true
        out[#out + 1] = rc
      end
    end
  end
  return out
end

--- KEY=VALUE lines; `export`, quotes and comments tolerated.
function M.dotenv(path)
  return cached(path, function(text)
    local env = {}
    for line in text:gmatch("[^\r\n]+") do
      local k, v = line:match("^%s*export%s+([%w_%.]+)%s*=%s*(.-)%s*$")
      if not k then
        k, v = line:match("^%s*([%w_%.]+)%s*=%s*(.-)%s*$")
      end
      if k then
        v = v:match('^"(.*)"$') or v:match("^'(.*)'$") or v:gsub("%s+#.*$", "")
        env[k] = v
      end
    end
    return env
  end) or {}
end

return M
