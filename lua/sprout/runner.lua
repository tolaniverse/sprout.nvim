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

-- Lets `bootRun`/`run` take JVM args and a main class from the environment,
-- and adds `sproutRun` to run any main class, so nothing has to be added to
-- the project's build script.
local INIT_SCRIPT = [[
def sproutJvmArgs = System.getenv('SPROUT_JVM_ARGS')
def sproutMain = System.getenv('SPROUT_MAIN_CLASS')
allprojects {
  if (sproutMain) {
    plugins.withId('java') {
      tasks.register('sproutRun', JavaExec) { t ->
        t.classpath = project.sourceSets.main.runtimeClasspath
        t.standardInput = System.in
      }
    }
  }
  tasks.withType(JavaExec).configureEach { t ->
    if (t.name == 'bootRun' || t.name == 'run' || t.name == 'sproutRun') {
      if (sproutJvmArgs) {
        t.jvmArgs(sproutJvmArgs.split('\u001f') as List)
      }
      if (sproutMain) {
        t.mainClass.set(sproutMain)
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

--- A main class's module directory ("services/api") → Gradle path / Maven -pl /
--- bleep project / Kotlin Toolchain module (named after its directory).
local function module_from_dir(p, dir)
  if dir == "" then
    return nil
  end
  if p.tool == "gradle" then
    return ":" .. dir:gsub("/", ":")
  elseif p.tool == "maven" then
    return dir
  end
  return vim.fs.basename(dir)
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
  local module = s.module
  if rc.dir then -- a detected main class: its own module, even the root one
    module = module_from_dir(p, rc.dir)
  elseif rc.module then
    module = module_from_idea(p, rc.module) or s.module
  end
  return {
    profiles = rc.profiles or s.profiles,
    vmArgs = list(s.vmArgs or {}, rc.vmArgs or {}),
    args = list(s.args or {}, rc.args or {}),
    env = env,
    module = module,
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

local function pom_has_exec_main(root)
  local fd = io.open(root .. "/pom.xml", "r")
  if not fd then
    return false
  end
  local pom = fd:read("*a")
  fd:close()
  return pom:find("exec-maven-plugin", 1, true) ~= nil and pom:find("<mainClass>", 1, true) ~= nil
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
  if (action == "run" or action == "debug") and config.ktor.development and project.is_ktor(p.root) then
    vm[#vm + 1] = "-Dio.ktor.development=true"
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
    local task = "run"
    if project.is_boot(p.root) then
      task = "bootRun"
    elseif rs.main and not project.uses(p.root, "io.ktor.plugin") then
      -- Ktor's Gradle plugin brings `application`, whose `run` keeps the
      -- build's applicationDefaultJvmArgs; elsewhere `run` may not exist.
      task = "sproutRun"
    end
    -- A bare task would run in every subproject too; a main class in the
    -- root module runs in the root project only.
    local root_only = rs.main and not rs.module and task ~= "bootRun"
    local target = root_only and (":" .. task) or gradle_task(rs.module, task)
    local cmd = { p.exe, "--init-script", init_script(), target }
    if #rs.args > 0 then
      cmd[#cmd + 1] = "--args=" .. table.concat(rs.args, " ")
    end
    if #vm > 0 then
      env.SPROUT_JVM_ARGS = table.concat(vm, SEP)
    end
    env.SPROUT_MAIN_CLASS = rs.main
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
    if project.is_boot(p.root) then
      cmd[#cmd + 1] = "spring-boot:run"
      if rs.main then
        cmd[#cmd + 1] = "-Dspring-boot.run.main-class=" .. rs.main
      end
      if #vm > 0 then
        cmd[#cmd + 1] = "-Dspring-boot.run.jvmArguments=" .. table.concat(vm, " ")
      end
      if #rs.args > 0 then
        cmd[#cmd + 1] = "-Dspring-boot.run.arguments=" .. table.concat(rs.args, " ")
      end
    else
      -- Without a picked main class, exec:java can still use the pom's own
      -- <mainClass> (Ktor's Maven template sets one).
      if not rs.main and not pom_has_exec_main(p.root) then
        return nil, "no main class: add a main function or an IntelliJ Application run configuration"
      end
      vim.list_extend(cmd, { "compile", "exec:java" })
      if rs.main then
        cmd[#cmd + 1] = "-Dexec.mainClass=" .. rs.main
      end
      if #rs.args > 0 then
        cmd[#cmd + 1] = "-Dexec.args=" .. table.concat(rs.args, " ")
      end
      if #vm > 0 then
        env.MAVEN_OPTS = table.concat(vm, " ")
      end
    end
    return cmd, env
  elseif p.tool == "kotlin" then
    local mod = rs.module and { "-m", (rs.module:gsub("^:", "")) } or {}
    if action == "build" or action == "clean" then
      return list({ p.exe, action }, action == "build" and mod or {}), env
    elseif action == "test" then
      return list({ p.exe, "test" }, rs.module and { "--include-module", (rs.module:gsub("^:", "")) } or {}), env
    end
    local cmd = list({ p.exe, "run" }, mod)
    if rs.main then
      cmd[#cmd + 1] = "--main-class=" .. rs.main
    end
    -- One flag per argument: the CLI splits each value on spaces.
    for _, a in ipairs(vm) do
      cmd[#cmd + 1] = "--jvm-args=" .. a
    end
    return list(cmd, #rs.args > 0 and list({ "--" }, rs.args) or {}), env
  else -- bleep
    local verbs = { build = "compile", test = "test", clean = "clean" }
    if verbs[action] then
      return { p.exe, verbs[action], rs.module }, env
    end
    if action == "debug" then
      return nil, "debug isn't supported for bleep builds yet; use Metals' debug"
    end
    local cmd = { p.exe, "run", rs.module or p.name }
    if rs.main then
      vim.list_extend(cmd, { "--class", rs.main })
    end
    return list(cmd, #rs.args > 0 and list({ "--" }, rs.args) or {}), env
  end
end

--- Registers Mason's kotlin-debug-adapter unless something (LazyVim's
--- kotlin extra) already did. Returns whether a kotlin adapter exists.
local function kotlin_adapter(dap)
  if dap.adapters.kotlin then
    return true
  end
  local exe = vim.fn.exepath("kotlin-debug-adapter")
  if exe == "" then
    exe = vim.fn.stdpath("data") .. "/mason/bin/kotlin-debug-adapter"
    if vim.fn.executable(exe) == 0 then
      return false
    end
  end
  dap.adapters.kotlin = {
    type = "executable",
    command = exe,
    args = { "--interpreter=vscode" },
    options = { initialize_timeout_sec = 20 }, -- it resolves the classpath first
  }
  return true
end

local function attach_debugger(root, port)
  local ok, dap = pcall(require, "dap")
  if not ok then
    return vim.notify("sprout: nvim-dap is not installed", vim.log.levels.WARN)
  end
  local want = config.run.debug_adapter
  if want == nil then
    want = (root and project.has_kotlin(root) and kotlin_adapter(dap)) and "kotlin" or "java"
  end
  if want == "kotlin" then
    if not kotlin_adapter(dap) then
      return vim.notify("sprout: kotlin-debug-adapter not found: `:MasonInstall kotlin-debug-adapter`", vim.log.levels.WARN)
    end
    return dap.run({
      type = "kotlin",
      request = "attach",
      name = "sprout attach",
      projectRoot = root or vim.uv.cwd(),
      hostName = "127.0.0.1",
      port = port,
      timeout = 10000,
    })
  end
  if not dap.adapters.java then
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
              attach_debugger(p.root, port)
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
    return vim.notify("sprout: no Gradle, Maven, Kotlin Toolchain or bleep project here", vim.log.levels.WARN)
  end
  return fn(p)
end

---@param debug? boolean
---@param repick? boolean ask for the run configuration again
function M.run(debug, repick)
  with_project(function(p)
    local action = debug and "debug" or "run"
    local rcs = idea.run_configs(p.root)
    -- Main classes found in the sources, unless a run configuration covers them.
    local covered = {}
    for _, rc in ipairs(rcs) do
      if rc.main then
        covered[rc.main] = true
      end
    end
    for _, m in ipairs(project.mains(p.root, p.tool)) do
      if not covered[m.class] then
        rcs[#rcs + 1] = { name = m.class, main = m.class, dir = m.dir }
      end
    end
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
        if rc.dir then
          return rc.name .. (rc.dir ~= "" and (" (" .. rc.dir .. ")") or "") .. " [main]"
        end
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

--- `quiet` is set when relaunching, which keeps the pane open for the next task.
function M.stop(root, quiet)
  root = root or project.root()
  local t = root and tasks[root]
  local was_running = t and t.job
  if was_running then
    vim.fn.jobstop(t.job)
    vim.fn.jobwait({ t.job }, 3000)
    t.job = nil
  end
  if quiet then
    return
  end
  -- The output buffer is kept, so :Sprout toggle can bring it back.
  if t and t.win and vim.api.nvim_win_is_valid(t.win) then
    if pcall(vim.api.nvim_win_close, t.win, false) then -- fails if it's the last window
      t.win = nil
    end
  elseif not was_running then
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
  attach_debugger(project.root(), config.run.debug_port)
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
