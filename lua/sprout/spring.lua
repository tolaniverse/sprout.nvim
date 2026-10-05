-- Spring and Ktor navigation without a second language server: endpoints and
-- config files, found with ripgrep and shown in snacks.picker (or vim.ui.select).
local project = require("sprout.project")

local M = {}

local METHODS = {
  GetMapping = "GET",
  PostMapping = "POST",
  PutMapping = "PUT",
  DeleteMapping = "DELETE",
  PatchMapping = "PATCH",
  RequestMapping = "ANY",
}

--- First path in an annotation's arguments: ("/x"), (value = "/x"), (path = ["/x"]).
local function mapping_path(args)
  if not args then
    return ""
  end
  local named = args:match('path%s*=%s*[{%[]?%s*"([^"]*)"') or args:match('value%s*=%s*[{%[]?%s*"([^"]*)"')
  return named or args:match('^%(%s*[{%[]?%s*"([^"]*)"') or ""
end

local function join(a, b)
  local s = ("/" .. a .. "/" .. b):gsub("/+", "/")
  return #s > 1 and s:gsub("/$", "") or s
end

local function request_method(args)
  local m = args and args:match("RequestMethod%.(%u+)")
  return m or "ANY"
end

--- Parse one controller file into endpoints.
local function parse(file, lines, out)
  local prefix, class_seen = "", false
  -- Annotations can span lines; join each annotation's text up to its ")".
  for i, line in ipairs(lines) do
    if not class_seen and line:match("^%s*[%w%s]*class%s+%w") then
      class_seen = true
    end
    local name, rest = line:match("@(%a+Mapping)(.*)")
    if name and METHODS[name] then
      local args = rest:match("^%s*(%b())")
      if not args and rest:match("^%s*%(") then
        args = table.concat(lines, " ", i, math.min(i + 5, #lines)):match("@" .. name .. "%s*(%b())")
      end
      local path = mapping_path(args)
      if not class_seen then
        prefix = path
      else
        local method = name == "RequestMapping" and request_method(args) or METHODS[name]
        local full = join(prefix, path)
        out[#out + 1] = {
          text = ("%-6s %s"):format(method, full),
          method = method,
          path = full,
          file = file,
          pos = { i, (line:find("@") or 1) - 1 },
        }
      end
    end
  end
end

local KTOR_METHODS = {
  get = "GET",
  post = "POST",
  put = "PUT",
  delete = "DELETE",
  patch = "PATCH",
  head = "HEAD",
  options = "OPTIONS",
  webSocket = "WS",
  sse = "SSE",
}

--- Blank out string literals and line comments, so braces in them don't count.
local function code_only(line)
  return (line:gsub('"""', ""):gsub('"[^"]*"', '""'):gsub("'\\?.'", "''"):gsub("//.*$", ""))
end

--- `@Resource("/articles") class Articles` → resources.Articles = "/articles".
--- Nested classes are keyed by their dotted name too ("Articles.New").
local function parse_resources(lines, resources)
  local pending
  local outer = {} ---@type {name: string, depth: integer}[]
  local depth = 0
  for _, line in ipairs(lines) do
    local code = code_only(line)
    pending = line:match('@Resource%(%s*"([^"]*)"') or pending
    local name = code:match("class%s+([%w_]+)")
    if name and pending then
      local parent = outer[#outer]
      local path = parent and join(resources[parent.name] or "", pending) or pending
      local dotted = parent and (parent.name .. "." .. name) or name
      resources[dotted] = path
      resources[name] = resources[name] or path
      if code:find("{", 1, true) then
        outer[#outer + 1] = { name = dotted, depth = depth + 1 }
      end
      pending = nil
    end
    depth = depth + select(2, code:gsub("{", "")) - select(2, code:gsub("}", ""))
    while outer[#outer] and depth < outer[#outer].depth do
      outer[#outer] = nil
    end
  end
end

--- Parse a Ktor routing DSL file: `route("/api") { get("/x") { … } }`,
--- `get { … }` (the enclosing route's path) and type-safe `get<Articles>`.
local function parse_ktor(file, lines, out, resources)
  resources = resources or {}
  local depth = 0
  local routes = {} ---@type {path: string, depth: integer}[]
  local function prefix()
    return routes[#routes] and routes[#routes].path or ""
  end
  for i, line in ipairs(lines) do
    local indent, call, rest = line:match("^(%s*)([%a]+)%s*(.*)$")
    local code = code_only(line)
    local opens = select(2, code:gsub("{", ""))
    if call == "route" then
      local path = rest:match('^%(%s*"([^"]*)"')
      -- A route that opens a block nests everything until that block closes.
      if path and opens > 0 then
        routes[#routes + 1] = { path = join(prefix(), path), depth = depth + 1 }
      end
    elseif call and KTOR_METHODS[call] then
      local path = rest:match('^%(%s*"([^"]*)"')
      local resource = rest:match("^<%s*([%w_%.]+)")
      if path or resource or rest:match("^[{(]") then
        local method = KTOR_METHODS[call]
        local full
        if resource and resources[resource] then
          full = join(prefix(), resources[resource])
        elseif resource then
          full = prefix() .. " <" .. resource .. ">"
        else
          full = join(prefix(), path or "")
        end
        out[#out + 1] = {
          text = ("%-6s %s"):format(method, full),
          method = method,
          path = full,
          file = file,
          pos = { i, #indent },
        }
      end
    end
    depth = depth + opens - select(2, code:gsub("}", ""))
    while routes[#routes] and depth < routes[#routes].depth do
      routes[#routes] = nil
    end
  end
end

local function pick(items, title, fmt)
  if #items == 0 then
    return vim.notify("sprout: no " .. title:lower() .. " found", vim.log.levels.INFO)
  end
  local ok, Snacks = pcall(require, "snacks")
  if ok and Snacks.picker then
    return Snacks.picker.pick({ title = title, items = items, format = fmt or "text", preview = "file" })
  end
  vim.ui.select(items, {
    prompt = title,
    format_item = function(it)
      return it.text
    end,
  }, function(it)
    if it then
      vim.cmd.edit(vim.fn.fnameescape(it.file))
      vim.api.nvim_win_set_cursor(0, { it.pos[1], it.pos[2] })
    end
  end)
end

local function method_hl(method)
  return ({ GET = "DiagnosticOk", POST = "DiagnosticWarn", PUT = "DiagnosticInfo", DELETE = "DiagnosticError" })[method]
    or "Special"
end

function M.endpoints()
  local p = project.current()
  if not p then
    return vim.notify("sprout: no project here", vim.log.levels.WARN)
  end
  if vim.fn.executable("rg") == 0 then
    return vim.notify("sprout: ripgrep (rg) is required", vim.log.levels.ERROR)
  end
  vim.system({
    "rg", "--files-with-matches", "--glob", "*.java", "--glob", "*.kt",
    "--glob", "!**/build/**", "--glob", "!**/target/**",
    "-e", "@(Get|Post|Put|Delete|Patch|Request)Mapping", "-e", "io\\.ktor\\.(server\\.(routing|resources|websocket|sse)|resources)",
    p.root,
  }, { text = true }, function(res)
    local items, ktor, resources = {}, {}, {}
    for file in (res.stdout or ""):gmatch("[^\n]+") do
      local lines = vim.fn.readfile(file)
      local text = table.concat(lines, "\n")
      if text:find("Mapping", 1, true) then
        parse(file, lines, items)
      end
      if file:match("%.kt$") then
        if text:find("@Resource(", 1, true) then
          parse_resources(lines, resources)
        end
        if text:find("io.ktor.server.", 1, true) then
          ktor[#ktor + 1] = { file, lines }
        end
      end
    end
    -- After every @Resource class is known, so get<Articles> shows its path.
    for _, f in ipairs(ktor) do
      parse_ktor(f[1], f[2], items, resources)
    end
    table.sort(items, function(a, b)
      return a.path == b.path and a.method < b.method or a.path < b.path
    end)
    vim.schedule(function()
      pick(items, "Endpoints", function(it)
        local rel = vim.fn.fnamemodify(it.file, ":t")
        return {
          { ("%-6s "):format(it.method), method_hl(it.method) },
          { it.path, "Normal" },
          { "  " .. rel .. ":" .. it.pos[1], "Comment" },
        }
      end)
    end)
  end)
end

--- application*.yml / .yaml / .properties (and Ktor's .conf) across all modules.
function M.config_files()
  local p = project.current()
  if not p then
    return vim.notify("sprout: no project here", vim.log.levels.WARN)
  end
  local res = vim.system({
    "rg", "--files", "--glob", "{application,bootstrap}*.{yml,yaml,properties,conf}",
    "--glob", "!**/build/**", "--glob", "!**/target/**", p.root,
  }, { text = true }):wait()
  local items = {}
  for f in (res.stdout or ""):gmatch("[^\n]+") do
    items[#items + 1] = { text = vim.fn.fnamemodify(f, ":~:."), file = f, pos = { 1, 0 } }
  end
  table.sort(items, function(x, y)
    return x.text < y.text
  end)
  pick(items, "Config files")
end

M._parse = parse
M._parse_ktor = parse_ktor
M._parse_resources = parse_resources

return M
