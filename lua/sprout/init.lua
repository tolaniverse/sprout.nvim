local config = require("sprout.config")

local M = {}

-- Bumped on release; must match the git tag (checked by .github/workflows/release.yml).
M.version = "0.2.0"

local function lazy(mod, fn)
  return function(...)
    return require(mod)[fn](...)
  end
end

M.run = lazy("sprout.runner", "run")
M.stop = lazy("sprout.runner", "stop")
M.restart = lazy("sprout.runner", "restart")
M.toggle = lazy("sprout.runner", "toggle")
M.endpoints = lazy("sprout.spring", "endpoints")
M.config_files = lazy("sprout.spring", "config_files")

--- JAVA_HOME for a project, e.g. for another LSP's cmd_env.
function M.java_home(root)
  local j = require("sprout.jdk").resolve(root or require("sprout.project").root())
  return j and j.home
end

function M.info()
  local project = require("sprout.project")
  local p = project.current()
  if not p then
    return vim.notify("sprout: no Gradle, Maven or bleep project here", vim.log.levels.WARN)
  end
  local jdk = require("sprout.jdk")
  local jdtls = require("sprout.jdtls")
  local idea = require("sprout.idea")
  local runner = require("sprout.runner")
  local j = jdk.resolve(p.root)
  local runner_jdk = jdk.find(config.jdtls.java, true)
  local cmd = runner._command(p, "run", runner._run_settings(p))
  local lines = {
    "# sprout",
    "",
    ("- **root** `%s`"):format(vim.fn.fnamemodify(p.root, ":~")),
    ("- **build** %s (`%s`)"):format(p.tool, vim.fn.fnamemodify(p.exe, ":~:.")),
    ("- **project JDK** %s"):format(j and ("%s `%s` — from %s"):format(j.version, j.id, j.source) or "none found"),
    ("- **jdtls JDK** %s"):format(runner_jdk and runner_jdk.version or "none ≥ " .. config.jdtls.java),
    ("- **lombok** `%s`"):format(jdtls.lombok() and vim.fn.fnamemodify(jdtls.lombok(), ":~") or "not found"),
    ("- **jdtls workspace** `%s`"):format(vim.fn.fnamemodify(jdtls.workspace_dir(p.root), ":~")),
    ("- **.idea/sprout.json** %s"):format(vim.uv.fs_stat(p.root .. "/.idea/sprout.json") and "yes" or "no (`:Sprout init`)"),
    "",
    "## Run configurations",
  }
  local rcs = idea.run_configs(p.root)
  if #rcs == 0 then
    lines[#lines + 1] = "- (none; defaults from .idea/sprout.json)"
  end
  for _, rc in ipairs(rcs) do
    lines[#lines + 1] = ("- %s%s"):format(rc.name, rc.profiles and (" [" .. table.concat(rc.profiles, ",") .. "]") or "")
  end
  vim.list_extend(lines, { "", "## Run command", "", "```sh", cmd and table.concat(cmd, " ") or "n/a", "```" })
  vim.list_extend(lines, { "", "## JDKs" })
  for _, x in ipairs(jdk.list()) do
    lines[#lines + 1] = ("- %d  %s  `%s`"):format(x.major, x.id, vim.fn.fnamemodify(x.home, ":~"))
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  local width = math.min(100, vim.o.columns - 4)
  local height = math.min(#lines, vim.o.lines - 6)
  vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    border = "rounded",
    title = " sprout ",
  })
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, nowait = true })
end

--- Create (or open) .idea/sprout.json.
function M.init()
  local p = require("sprout.project").current()
  if not p then
    return vim.notify("sprout: no project here", vim.log.levels.WARN)
  end
  local path = p.root .. "/.idea/sprout.json"
  if not vim.uv.fs_stat(path) then
    local j = require("sprout.jdk").resolve(p.root)
    require("sprout.idea").write_settings(p.root, {
      jdk = j and tostring(j.major) or nil,
      profiles = { "dev" },
      env = vim.empty_dict(),
      envFile = vim.uv.fs_stat(p.root .. "/.env") and ".env" or nil,
      vmArgs = {},
      args = {},
    })
  end
  vim.cmd.edit(vim.fn.fnameescape(path))
end

--- Push fresh settings to a running jdtls for the project.
local function refresh_jdtls(root)
  for _, client in ipairs(vim.lsp.get_clients({ name = "jdtls" })) do
    if client.root_dir == root then
      client.settings = require("sprout.jdtls").settings(root, client.settings)
      client:notify("workspace/didChangeConfiguration", { settings = client.settings })
    end
  end
end

--- Pick the project JDK and save it to .idea/sprout.json.
function M.pick_jdk()
  local p = require("sprout.project").current()
  if not p then
    return
  end
  local jdk = require("sprout.jdk")
  vim.ui.select(jdk.list(), {
    prompt = "Project JDK",
    format_item = function(j)
      return ("%-3d %s"):format(j.major, j.id)
    end,
  }, function(j)
    if not j then
      return
    end
    local idea = require("sprout.idea")
    local s = vim.deepcopy(idea.settings(p.root))
    s.jdk = j.id
    idea.write_settings(p.root, s)
    refresh_jdtls(p.root)
    vim.notify(("sprout: %s now uses %s"):format(p.name, j.id))
  end)
end

--- Delete Eclipse metadata an earlier jdtls/Eclipse left in the project, then
--- wipe the jdtls workspace so it re-imports without them.
function M.unclutter()
  local p = require("sprout.project").current()
  if not p then
    return
  end
  local found = {}
  local function scan(dir)
    for _, n in ipairs({ ".project", ".classpath", ".factorypath", ".settings" }) do
      if vim.uv.fs_stat(dir .. "/" .. n) then
        found[#found + 1] = dir .. "/" .. n
      end
    end
    -- Eclipse's output folder, only when its .classpath says so.
    local fd = io.open(dir .. "/.classpath", "r")
    if fd then
      local cp = fd:read("*a")
      fd:close()
      local out = cp:match('kind="output"%s+path="([^"]+)"') or cp:match('path="([^"]+)"%s+kind="output"')
      if out == "bin" and vim.uv.fs_stat(dir .. "/bin") then
        found[#found + 1] = dir .. "/bin"
      end
    end
  end
  scan(p.root)
  local res = vim.system({ "rg", "--files", "--hidden", "--glob", "**/.project", "--glob", "!**/node_modules/**", p.root }, { text = true }):wait()
  for f in (res.stdout or ""):gmatch("[^\n]+") do
    local dir = vim.fs.dirname(f)
    if dir ~= p.root then
      scan(dir)
    end
  end
  if #found == 0 then
    return vim.notify("sprout: no Eclipse files here")
  end
  local rel = vim.tbl_map(function(f)
    return vim.fn.fnamemodify(f, ":~:.")
  end, found)
  vim.ui.select({ "Delete", "Cancel" }, { prompt = "Delete " .. table.concat(rel, ", ") .. "?" }, function(choice)
    if choice ~= "Delete" then
      return
    end
    for _, f in ipairs(found) do
      vim.fn.delete(f, "rf")
    end
    vim.fn.delete(require("sprout.jdtls").workspace_dir(p.root), "rf")
    vim.notify(("sprout: removed %d Eclipse files; restart jdtls (:LspRestart jdtls)"):format(#found))
  end)
end

local subcommands = {
  run = function(a)
    M.run(false, a.bang)
  end,
  debug = function(a)
    require("sprout.runner").run(true, a.bang)
  end,
  attach = lazy("sprout.runner", "attach"),
  stop = function()
    M.stop()
  end,
  restart = M.restart,
  build = function()
    require("sprout.runner").task("build")
  end,
  test = function()
    require("sprout.runner").task("test")
  end,
  clean = function()
    require("sprout.runner").task("clean")
  end,
  exec = function(a)
    require("sprout.runner").exec(vim.list_slice(a.fargs, 2))
  end,
  toggle = M.toggle,
  endpoints = M.endpoints,
  config = M.config_files,
  datasource = function()
    require("sprout.datasource").run()
  end,
  info = M.info,
  version = function()
    vim.notify("sprout.nvim " .. M.version)
  end,
  init = M.init,
  jdk = M.pick_jdk,
  unclutter = M.unclutter,
  reload = function()
    require("sprout.reload").reload()
  end,
  wipe = function()
    require("jdtls.setup").wipe_data_and_restart()
  end,
}

function M.command(a)
  local name = a.fargs[1] or "info"
  local fn = subcommands[name]
  if not fn then
    return vim.notify("sprout: unknown subcommand " .. name, vim.log.levels.ERROR)
  end
  fn(a)
end

function M.complete(arglead, line)
  if line:match("^%S+%s+%S+%s") then
    return {}
  end
  return vim.tbl_filter(function(k)
    return k:find(arglead, 1, true) == 1
  end, vim.tbl_keys(subcommands))
end

function M.setup(opts)
  config.setup(opts)
  require("sprout.spring_ls").setup()
  if config.jdtls.enabled then
    vim.api.nvim_create_autocmd("FileType", {
      group = vim.api.nvim_create_augroup("sprout.jdtls", { clear = true }),
      pattern = "java",
      callback = function(ev)
        local cfg = require("sprout.jdtls").config(ev.buf)
        if cfg then
          require("jdtls").start_or_attach(cfg)
        end
      end,
    })
    if vim.bo.filetype == "java" then
      vim.api.nvim_exec_autocmds("FileType", { group = "sprout.jdtls", pattern = "java" })
    end
  end
end

return M
