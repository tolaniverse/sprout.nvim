-- Spring navigation without a second language server: endpoints and config
-- files, found with ripgrep and shown in snacks.picker (or vim.ui.select).
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
    "@(Get|Post|Put|Delete|Patch|Request)Mapping", p.root,
  }, { text = true }, function(res)
    local items = {}
    for file in (res.stdout or ""):gmatch("[^\n]+") do
      parse(file, vim.fn.readfile(file), items)
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

--- application*.yml / .yaml / .properties across all modules.
function M.config_files()
  local p = project.current()
  if not p then
    return vim.notify("sprout: no project here", vim.log.levels.WARN)
  end
  local res = vim.system({
    "rg", "--files", "--glob", "{application,bootstrap}*.{yml,yaml,properties}",
    "--glob", "!**/build/**", "--glob", "!**/target/**", p.root,
  }, { text = true }):wait()
  local items = {}
  for f in (res.stdout or ""):gmatch("[^\n]+") do
    items[#items + 1] = { text = vim.fn.fnamemodify(f, ":~:."), file = f, pos = { 1, 0 } }
  end
  table.sort(items, function(x, y)
    return x.text < y.text
  end)
  pick(items, "Spring config")
end

M._parse = parse

return M
