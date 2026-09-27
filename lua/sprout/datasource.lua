-- :Sprout datasource — write a working spring.datasource (+ spring.jpa) block
-- for the JDBC driver the build already depends on, into application.yml or
-- application.properties. Values are ${ENV:default} placeholders, so real
-- credentials can come from the environment / .env (see :Sprout run).
local project = require("sprout.project")

local M = {}

---@class sprout.Db
---@field name string
---@field dep string   substring identifying the driver dependency in a build file
---@field driver string
---@field url string   %s = database name
---@field user string
---@field password string

---@type sprout.Db[]
M.DATABASES = {
  { name = "PostgreSQL", dep = "org.postgresql", driver = "org.postgresql.Driver", url = "jdbc:postgresql://localhost:5432/%s", user = "postgres", password = "postgres" },
  { name = "MySQL", dep = "mysql-connector", driver = "com.mysql.cj.jdbc.Driver", url = "jdbc:mysql://localhost:3306/%s", user = "root", password = "" },
  { name = "MariaDB", dep = "mariadb-java-client", driver = "org.mariadb.jdbc.Driver", url = "jdbc:mariadb://localhost:3306/%s", user = "root", password = "" },
  { name = "H2 (in-memory)", dep = "com.h2database", driver = "org.h2.Driver", url = "jdbc:h2:mem:%s", user = "sa", password = "" },
  { name = "SQL Server", dep = "mssql-jdbc", driver = "com.microsoft.sqlserver.jdbc.SQLServerDriver", url = "jdbc:sqlserver://localhost:1433;databaseName=%s;encrypt=false", user = "sa", password = "" },
  { name = "Oracle", dep = "ojdbc", driver = "oracle.jdbc.OracleDriver", url = "jdbc:oracle:thin:@localhost:1521/FREEPDB1", user = "system", password = "" },
}

local function build_files_text(root)
  local res = vim.system({
    "rg", "--no-filename", "--max-depth", "3", "--glob",
    "{pom.xml,build.gradle,build.gradle.kts,libs.versions.toml}", "", root,
  }, { text = true }):wait()
  return res.stdout or ""
end

--- Databases whose driver the build depends on, and whether it uses Data JPA.
function M.detect(root)
  local text = build_files_text(root)
  local found = vim.tbl_filter(function(db)
    return text:find(db.dep, 1, true) ~= nil
  end, M.DATABASES)
  return found, text:find("spring-boot-starter-data-jpa", 1, true) ~= nil
end

--- Flat key/value pairs for the chosen database, in insertion order.
function M.properties(db, dbname, jpa)
  local props = {
    { "spring.datasource.url", ("${DB_URL:%s}"):format(db.url:format(dbname)) },
    { "spring.datasource.username", ("${DB_USERNAME:%s}"):format(db.user) },
    { "spring.datasource.password", ("${DB_PASSWORD:%s}"):format(db.password) },
    { "spring.datasource.driver-class-name", db.driver },
  }
  if jpa then
    vim.list_extend(props, {
      { "spring.jpa.hibernate.ddl-auto", "update" },
      { "spring.jpa.open-in-view", "false" },
    })
  end
  return props
end

--- Drop spring.jpa.* when the file already configures JPA (no duplicate keys).
local function without_jpa(props)
  return vim.tbl_filter(function(kv)
    return not kv[1]:find("^spring%.jpa%.")
  end, props)
end

local function yaml_value(v)
  -- ${…} and empty strings must be quoted in YAML.
  if v == "" or v:find("[{}:#]") then
    return '"' .. v:gsub('"', '\\"') .. '"'
  end
  return v
end

--- Nest `spring.x.y: v` pairs under their shared prefixes, `indent` spaces per level.
local function to_yaml(props, indent, depth_offset)
  local lines, open = {}, {}
  for _, kv in ipairs(props) do
    local parts = vim.split(kv[1], ".", { plain = true })
    local common = 0
    while common < #open and common < #parts - 1 and open[common + 1] == parts[common + 1] do
      common = common + 1
    end
    for i = #open, common + 1, -1 do
      open[i] = nil
    end
    for i = common + 1, #parts - 1 do
      lines[#lines + 1] = (" "):rep(indent * (i - 1 + depth_offset)) .. parts[i] .. ":"
      open[i] = parts[i]
    end
    lines[#lines + 1] = (" "):rep(indent * (#parts - 1 + depth_offset)) .. parts[#parts] .. ": " .. yaml_value(kv[2])
  end
  return lines
end

---@return integer? row of an existing top-level `spring:` (1-based)
local function find_top(lines, key)
  for i, l in ipairs(lines) do
    if l:match("^" .. key .. ":%s*$") or l:match("^" .. key .. ":%s+#") then
      return i
    end
  end
end

--- Indent used by the file (first indented key), default 2.
local function detect_indent(lines)
  for _, l in ipairs(lines) do
    local sp = l:match("^( +)%S")
    if sp then
      return #sp
    end
  end
  return 2
end

--- Insert into a YAML buffer. Returns the row to put the cursor on, or nil + reason.
function M.insert_yaml(buf, props)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local text = table.concat(lines, "\n")
  if text:find("\n%s+datasource:") or text:find("^%s*datasource:") or text:find("spring%.datasource%.") then
    return nil, "a datasource is already configured here"
  end
  if text:find("\n%s+jpa:") or text:find("spring%.jpa%.") then
    props = without_jpa(props)
  end
  local indent = detect_indent(lines)
  local spring = find_top(lines, "spring")
  if spring then
    -- Everything below spring:, one level in.
    local sub = vim.tbl_map(function(kv)
      return { kv[1]:gsub("^spring%.", ""), kv[2] }
    end, props)
    local block = to_yaml(sub, indent, 1)
    vim.api.nvim_buf_set_lines(buf, spring, spring, false, block)
    return spring + 2 -- the url line (spring:, datasource:, url:)
  end
  local block = to_yaml(props, indent, 0)
  local at = #lines
  if lines[at] == "" then
    at = at - 1
  end
  if at > 0 then
    table.insert(block, 1, "")
  end
  vim.api.nvim_buf_set_lines(buf, at, -1, false, block)
  return at + (at > 0 and 4 or 3)
end

function M.insert_properties(buf, props)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for _, l in ipairs(lines) do
    if l:match("^%s*spring%.datasource%.") then
      return nil, "a datasource is already configured here"
    end
    if l:match("^%s*spring%.jpa%.") then
      props = without_jpa(props)
    end
  end
  local block = vim.tbl_map(function(kv)
    return kv[1] .. "=" .. kv[2]
  end, props)
  local at = #lines
  if lines[at] == "" then
    at = at - 1
  end
  if at > 0 then
    table.insert(block, 1, "")
  end
  vim.api.nvim_buf_set_lines(buf, at, -1, false, block)
  return at + (at > 0 and 2 or 1)
end

--- The config file to write into: the current buffer if it is one, else the
--- main application.{yml,yaml,properties}, else a new application.yml.
local function target(root)
  local cur = vim.api.nvim_buf_get_name(0)
  local base = vim.fs.basename(cur)
  if base:match("^application.*%.ya?ml$") or base:match("^application.*%.properties$") then
    return cur
  end
  local res = root .. "/src/main/resources/"
  for _, n in ipairs({ "application.yml", "application.yaml", "application.properties" }) do
    if vim.uv.fs_stat(res .. n) then
      return res .. n
    end
  end
  return res .. "application.yml"
end

function M.run()
  local p = project.current()
  if not p then
    return vim.notify("sprout: no project here", vim.log.levels.WARN)
  end
  local found, jpa = M.detect(p.root)
  local choices = #found > 0 and found or M.DATABASES
  local function go(db)
    if not db then
      return
    end
    local file = target(p.root)
    vim.fn.mkdir(vim.fs.dirname(file), "p")
    vim.cmd.edit(vim.fn.fnameescape(file))
    local buf = vim.api.nvim_get_current_buf()
    local dbname = p.name:gsub("[^%w_]", "_")
    local props = M.properties(db, dbname, jpa)
    local row, err
    if file:match("%.properties$") then
      row, err = M.insert_properties(buf, props)
    else
      row, err = M.insert_yaml(buf, props)
    end
    if not row then
      return vim.notify("sprout: " .. err, vim.log.levels.WARN)
    end
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    local note = #found == 0 and (" — add the %s driver dependency to your build"):format(db.name) or ""
    vim.notify(("sprout: %s datasource added%s"):format(db.name, note))
  end
  if #choices == 1 then
    return go(choices[1])
  end
  vim.ui.select(choices, {
    prompt = #found > 0 and "Datasource" or "Datasource (no JDBC driver in the build yet)",
    format_item = function(db)
      return db.name
    end,
  }, go)
end

return M
