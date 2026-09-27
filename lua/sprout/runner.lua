-- Run / debug / build / test through the project's own build tool, on the
-- project's JDK, in one reusable terminal split per project.
local config = require("sprout.config")
local idea = require("sprout.idea")
local jdk = require("sprout.jdk")
local project = require("sprout.project")

local M = {}

---@class sprout.Task
---@field buf integer
---@field job integer?
---@field win integer?
---@field spec table what was run, for :Sprout restart

---@type table<string, sprout.Task>
local tasks = {}
---@type table<string, string> root -> last picked run configuration name
local last_rc = {}

local SEP = "\31" -- unit separator: JVM args can contain spaces

-- Lets `bootRun`/`run` take JVM args from the environment, so nothing has to
-- be added to the project's build script.
local INIT_SCRIPT = [[
def sproutJvmArgs = System.getenv('SPROUT_JVM_ARGS')
if (sproutJvmArgs) {
  allprojects {
    tasks.withType(JavaExec).configureEach { t ->
      if (t.name == 'bootRun' || t.name == 'run') {
        t.jvmArgs(sproutJvmArgs.split('\u001f') as List)
      }
    }
  }
}
]]

local function init_script()
  local path = vim.fn.stdpath("cache") .. "/sprout/sprout-init.gradle"
  local fd = io.open(path, "r")
  local current = fd and fd:read("*a")
  if fd then
    fd:close()
  end
  if current ~= INIT_SCRIPT then
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    fd = assert(io.open(path, "w"))
    fd:write(INIT_SCRIPT)
    fd:close()
  end
  return path
end

local function read(path)
  local fd = io.open(path, "r")
  if not fd then
    return ""
  end
  local s = fd:read("*a")
  fd:close()
  return s
end

local function is_boot(root)
  local f = read(root .. "/build.gradle.kts") .. read(root .. "/build.gradle") .. read(root .. "/pom.xml")
  return f:find("org.springframework.boot", 1, true) ~= nil
end

--- IntelliJ module names ("shop.api.main") → Gradle path (":api") / Maven selector (":api").
local function module_from_idea(p, name)
  if not name then
    return nil
  end
  name = name:gsub("%.main$", ""):gsub("%.test$", "")
  if p.tool == "gradle" then
    local parts = vim.split(name, ".", { plain = true })
    table.remove(parts, 1)
    return #parts > 0 and (":" .. table.concat(parts, ":")) or nil
  elseif p.tool == "maven" then
    return name ~= p.name and (":" .. name) or nil
  end
  return name
end

local function list(...)
  local out = {}
  for i = 1, select("#", ...) do
    vim.list_extend(out, (select(i, ...)))
  end
  return out
end

--- Merge .idea/sprout.json with an IntelliJ run configuration (which wins).
local function run_settings(p, rc)
  local s = idea.settings(p.root)
  rc = rc or {}
  local env = s.envFile and idea.dotenv(p.root .. "/" .. s.envFile) or {}
  env = vim.tbl_extend("force", env, s.env or {}, rc.env or {})
  return {
    profiles = rc.profiles or s.profiles,
    vmArgs = list(s.vmArgs or {}, rc.vmArgs or {}),
    args = list(s.args or {}, rc.args or {}),
    env = env,
    module = module_from_idea(p, rc.module) or s.module,
    main = rc.main,
  }
end

local function env_for(p, extra)
  local j = jdk.resolve(p.root)
  local env = vim.tbl_extend("force", {}, extra or {})
  if j then
    env.JAVA_HOME = j.home
    env.PATH = j.home .. "/bin:" .. vim.env.PATH
  end
  return env
end

local function gradle_task(mod, task)
  if not mod then
    return task
  end
  return (mod:sub(1, 1) == ":" and mod or ":" .. mod) .. ":" .. task
end

---@param action "run"|"debug"|"build"|"test"|"clean"
local function command(p, action, rs)
  rs = rs or run_settings(p)
  local port = config.run.debug_port
  local jdwp = ("-agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address=*:%d"):format(port)
  local vm = vim.deepcopy(rs.vmArgs or {})
  if action == "debug" then
    vm[#vm + 1] = jdwp
  end
  local env = vim.deepcopy(rs.env or {})
  if rs.profiles and #rs.profiles > 0 then
    env.SPRING_PROFILES_ACTIVE = table.concat(rs.profiles, ",")
  end

  if p.tool == "gradle" then
    local tasks_for = { build = "build", test = "test", clean = "clean" }
    if tasks_for[action] then
      local cmd = { p.exe, gradle_task(rs.module, tasks_for[action]) }
      if action == "build" then
        vim.list_extend(cmd, { "-x", "test" })
      end
      return cmd, env
    end
    local cmd = { p.exe, "--init-script", init_script(), gradle_task(rs.module, is_boot(p.root) and "bootRun" or "run") }
    if #rs.args > 0 then
      cmd[#cmd + 1] = "--args=" .. table.concat(rs.args, " ")
    end
    if #vm > 0 then
      env.SPROUT_JVM_ARGS = table.concat(vm, SEP)
    end
    return cmd, env
  elseif p.tool == "maven" then
    local cmd = { p.exe }
    if rs.module then
      vim.list_extend(cmd, { "-pl", rs.module })
    end
    local goals = { build = { "package", "-DskipTests" }, test = { "test" }, clean = { "clean" } }
    if goals[action] then
      return list(cmd, goals[action]), env
    end
    if is_boot(p.root) then
      cmd[#cmd + 1] = "spring-boot:run"
      if #vm > 0 then
        cmd[#cmd + 1] = "-Dspring-boot.run.jvmArguments=" .. table.concat(vm, " ")
      end
      if #rs.args > 0 then
        cmd[#cmd + 1] = "-Dspring-boot.run.arguments=" .. table.concat(rs.args, " ")
      end
    else
      if not rs.main then
        return nil, "no main class: add an IntelliJ Application run configuration"
      end
      vim.list_extend(cmd, { "compile", "exec:java", "-Dexec.mainClass=" .. rs.main })
      if #rs.args > 0 then
        cmd[#cmd + 1] = "-Dexec.args=" .. table.concat(rs.args, " ")
      end
      if #vm > 0 then
        env.MAVEN_OPTS = table.concat(vm, " ")
      end
    end
    return cmd, env
  else -- bleep
    local verbs = { build = "compile", test = "test", clean = "clean" }
    if verbs[action] then
      return { p.exe, verbs[action], rs.module }, env
    end
    if action == "debug" then
      return nil, "debug isn't supported for bleep builds yet; use Metals' debug"
    end
    return list({ p.exe, "run", rs.module or p.name }, #rs.args > 0 and list({ "--" }, rs.args) or {}), env
  end
end

local function attach_debugger(port)
  local ok, dap = pcall(require, "dap")
  if not ok or not dap.adapters.java then
    return vim.notify(
      "sprout: the java debug adapter isn't registered yet; open a Java file so jdtls starts, then :Sprout attach",
      vim.log.levels.WARN
    )
  end
  dap.run({ type = "java", request = "attach", name = "sprout attach", hostName = "127.0.0.1", port = port })
end

local function show(task)
  if task.win and vim.api.nvim_win_is_valid(task.win) then
    return task.win
  end
  local prev = vim.api.nvim_get_current_win()
  vim.cmd(("botright %dsplit"):format(config.run.height))
  task.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(task.win, task.buf)
  vim.wo[task.win].winfixheight = true
  vim.api.nvim_set_current_win(prev)
  return task.win
end

--- Run `cmd` in the project's terminal, replacing whatever ran there before.
local function launch(p, cmd, env, spec)
  M.stop(p.root, true)

  local old = tasks[p.root]
  local task = { buf = vim.api.nvim_create_buf(false, true), win = old and old.win, spec = spec }
  tasks[p.root] = task
  show(task)
  vim.api.nvim_win_set_buf(task.win, task.buf)
  if old and vim.api.nvim_buf_is_valid(old.buf) then
    vim.api.nvim_buf_delete(old.buf, { force = true })
  end

  local attached = spec.action ~= "debug"
  local port = config.run.debug_port
  vim.api.nvim_buf_call(task.buf, function()
    task.job = vim.fn.jobstart(cmd, {
      term = true,
      cwd = p.root,
      env = env_for(p, env),
      on_stdout = function(_, data)
        if attached then
          return
        end
        for _, line in ipairs(data) do
          if line:find("Listening for transport dt_socket", 1, true) then
            attached = true
            vim.schedule(function()
              attach_debugger(port)
            end)
            return
          end
        end
      end,
      on_exit = function(_, code)
        task.job = nil
        if code ~= 0 and code ~= 143 and code ~= 129 then
          vim.schedule(function()
            vim.notify(("sprout: %s exited with %d"):format(spec.action, code), vim.log.levels.WARN)
          end)
        end
      end,
    })
  end)
  pcall(vim.api.nvim_buf_set_name, task.buf, ("sprout://%s/%s"):format(p.name, spec.label or spec.action))
  -- Park the cursor at the end so the terminal follows the output.
  vim.api.nvim_win_call(task.win, function()
    vim.cmd("normal! G")
  end)
end

local function start(p, spec)
  local cmd, env = command(p, spec.action, spec.rs)
  if not cmd then
    return vim.notify("sprout: " .. env, vim.log.levels.ERROR)
  end
  launch(p, cmd, env, spec)
end

local function with_project(fn)
  local p = project.current()
  if not p then
    return vim.notify("sprout: no Gradle, Maven or bleep project here", vim.log.levels.WARN)
  end
  return fn(p)
end

---@param debug? boolean
---@param repick? boolean ask for the run configuration again
function M.run(debug, repick)
  with_project(function(p)
    local action = debug and "debug" or "run"
    local rcs = idea.run_configs(p.root)
    local function go(rc)
      if rc then
        last_rc[p.root] = rc.name
      end
      start(p, { action = action, rs = run_settings(p, rc), label = rc and rc.name })
    end
    if #rcs <= 1 then
      return go(rcs[1])
    end
    if not repick and last_rc[p.root] then
      for _, rc in ipairs(rcs) do
        if rc.name == last_rc[p.root] then
          return go(rc)
        end
      end
    end
    vim.ui.select(rcs, {
      prompt = "Run configuration",
      format_item = function(rc)
        local prof = rc.profiles and (" [" .. table.concat(rc.profiles, ",") .. "]") or ""
        return rc.name .. prof
      end,
    }, function(rc)
      if rc then
        go(rc)
      end
    end)
  end)
end

---@param action "build"|"test"|"clean"
function M.task(action)
  with_project(function(p)
    start(p, { action = action })
  end)
end

--- Raw build tool invocation: `:Sprout exec dependencies --configuration runtimeClasspath`.
function M.exec(args)
  with_project(function(p)
    launch(p, list({ p.exe }, args), {}, { action = "exec", label = "exec" })
  end)
end

function M.restart()
  with_project(function(p)
    local t = tasks[p.root]
    if not t then
      return M.run(false)
    end
    if t.spec.action == "exec" then
      return vim.notify("sprout: nothing to restart", vim.log.levels.INFO)
    end
    start(p, t.spec)
  end)
end

function M.stop(root, quiet)
  root = root or project.root()
  local t = root and tasks[root]
  if t and t.job then
    vim.fn.jobstop(t.job)
    vim.fn.jobwait({ t.job }, 3000)
    t.job = nil
  elseif not quiet then
    vim.notify("sprout: nothing running", vim.log.levels.INFO)
  end
end

function M.toggle()
  with_project(function(p)
    local t = tasks[p.root]
    if not t or not vim.api.nvim_buf_is_valid(t.buf) then
      return vim.notify("sprout: no output yet", vim.log.levels.INFO)
    end
    if t.win and vim.api.nvim_win_is_valid(t.win) then
      vim.api.nvim_win_close(t.win, false)
      t.win = nil
    else
      show(t)
    end
  end)
end

function M.attach()
  attach_debugger(config.run.debug_port)
end

-- Exposed for :Sprout info and tests.
M._command = command
M._run_settings = run_settings

-- Don't leave Spring apps running after Neovim exits.
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("sprout.runner", { clear = true }),
  callback = function()
    for _, t in pairs(tasks) do
      if t.job then
        pcall(vim.fn.jobstop, t.job)
      end
    end
  end,
})

return M
