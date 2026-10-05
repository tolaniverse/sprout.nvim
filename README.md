# sprout.nvim

Spring Boot, Ktor and JVM (Java and Kotlin) projects in Neovim, without Eclipse files in your repo.

- **No clutter**: jdtls keeps `.project`, `.classpath`, `.settings/` and `.factorypath` in
  `stdpath("cache")/sprout/jdtls/<project>-<hash>`. Your project gets nothing new except
  `.idea/`, if you want it.
- **`.idea/` is the config**: reads `.idea/sprout.json`, IntelliJ's `.idea/misc.xml`
  (project JDK) and its Spring Boot / Application run configurations.
- **Right JDK per project** (SDKMAN, `/Library/Java`, `JAVA_HOME`), in this order:
  `.idea/sprout.json` → `.sdkmanrc` → `.idea/misc.xml` → build file (toolchain,
  `java.version`, Kotlin `jvmTarget`, …) → SDKMAN `current`. jdtls itself always runs on JDK 21+.
- **Lombok** out of the box (Mason's jar).
- **Build file changed → "Reload classpath?"**: save `pom.xml`, `build.gradle(.kts)` or
  `libs.versions.toml` (or `git pull` a change) and you're asked, like IntelliJ. Choose
  now / always / not now / never; always and never are saved per project. You get a notification
  when the re-import finishes, and new dependencies then show up in completion.
- **Spring Boot language server** (Mason's `vscode-spring-boot-tools`), started only in Spring
  Boot projects: completion, validation and hover in `application*.yml`/`.properties`
  (from your actual dependencies), `@Value("${…}")` completion, and Spring symbols. sprout connects
  it to jdtls for classpath and type information, the way VS Code does.
- **IntelliJ-style `application.yml`**: type `datasource` (or even `sp.ds.url`) anywhere and
  pick `spring.datasource.url`; the nested `spring:` → `datasource:` → `url:` structure is
  inserted for you. Values complete too: driver classes from your classpath, `ddl-auto` modes,
  log levels, booleans. Works even when the YAML is the first file you open.
- **`:Sprout datasource`**: sets up the database in one go. It detects the JDBC driver in your
  build and writes `spring.datasource` (plus `spring.jpa` with Data JPA) with
  `${DB_URL:jdbc:postgresql://localhost:5432/app}`-style placeholders.
- **Completion tuned for Spring**: postfix templates, lazily resolved auto-imports, JUnit/
  AssertJ/Mockito/MockMvc static members, AWT/Swing/JDK internals filtered out.
- **Run / debug / build / test** via `gradlew`, `mvnw`, `bleep` or the Kotlin Toolchain's
  `kotlin` CLI (projects from `kotlin init`), on the project JDK, with
  profiles, env, `.env` and JVM args. Debug starts the app with JDWP and attaches nvim-dap.
- **Endpoints picker**: every `@GetMapping`/`@PostMapping`/… in Java and Kotlin, with the
  class-level `@RequestMapping` prefix included, and every Ktor route (`get("/x")`, `post { }`,
  `webSocket`, type-safe `get<Articles>`) with the paths of its enclosing `route("/api") { }`
  blocks and `@Resource` classes.
- **Ktor**: `:Sprout run` uses the `application` plugin's `run` task (Gradle) or `exec:java`
  (Maven) with Ktor's development mode on; `:Sprout config` lists `application.conf` too.
- **Kotlin**: top-level `fun main` (including `suspend` and `@file:JvmName`) is found for
  run/debug, and `:Sprout debug` attaches Mason's `kotlin-debug-adapter` in Kotlin projects,
  so breakpoints in `.kt` files work.
- **Small**: ~1.5k lines of Lua, no background work until you open a Java file or run a command.

## Install (LazyVim)

Requires `lazyvim.plugins.extras.lang.java` and `dap.core`. sprout plugs into the java
extra's jdtls setup, so only one jdtls is started.

```lua
-- lua/plugins/sprout.lua
return {
  {
    "tolaniverse/sprout.nvim",
    version = "*", -- latest release; drop it to follow main
    cmd = "Sprout",
    ft = { "java", "kotlin", "yaml", "jproperties" },
    opts = {},
    keys = {
      { "<leader>jr", "<cmd>Sprout run<cr>", desc = "Run app" },
      { "<leader>jR", "<cmd>Sprout run!<cr>", desc = "Run app (pick config)" },
      { "<leader>jd", "<cmd>Sprout debug<cr>", desc = "Debug app" },
      { "<leader>js", "<cmd>Sprout stop<cr>", desc = "Stop" },
      { "<leader>jl", "<cmd>Sprout restart<cr>", desc = "Restart last" },
      { "<leader>jb", "<cmd>Sprout build<cr>", desc = "Build" },
      { "<leader>jt", "<cmd>Sprout test<cr>", desc = "Test (build tool)" },
      { "<leader>jo", "<cmd>Sprout toggle<cr>", desc = "Toggle output" },
      { "<leader>je", "<cmd>Sprout endpoints<cr>", desc = "Endpoints" },
      { "<leader>jc", "<cmd>Sprout config<cr>", desc = "Config files" },
      { "<leader>ji", "<cmd>Sprout info<cr>", desc = "Project info" },
      { "<leader>jk", "<cmd>Sprout jdk<cr>", desc = "Pick project JDK" },
      { "<leader>ju", "<cmd>Sprout reload<cr>", desc = "Reload build config" },
      { "<leader>jD", "<cmd>Sprout datasource<cr>", desc = "Set up datasource" },
    },
  },
  {
    "mfussenegger/nvim-jdtls",
    dependencies = { "tolaniverse/sprout.nvim" },
    opts = function(_, opts)
      return require("sprout.jdtls").lazyvim_opts(opts)
    end,
  },
  -- Keep other Mason JVM servers from attaching next to jdtls, if you have them installed.
  {
    "neovim/nvim-lspconfig",
    opts = { servers = { java_language_server = { enabled = false }, gradle_ls = { enabled = false } } },
  },
}
```

Without LazyVim, install `mfussenegger/nvim-jdtls` and call
`require("sprout").setup({ jdtls = { enabled = true } })`.

## Commands

| `:Sprout …`   |                                                                  |
| ------------- | ---------------------------------------------------------------- |
| `run[!]`      | Run the app (`bootRun` / `spring-boot:run` / `bleep run` / `kotlin run`). `!` re-picks the run configuration or main class |
| `debug[!]`    | Same, with JDWP on port 5005, and attaches nvim-dap once it's listening (java-debug, or kotlin-debug-adapter in Kotlin projects) |
| `attach`      | Attach nvim-dap to port 5005                                     |
| `stop` / `restart` / `toggle` | Control the output terminal (`stop` also closes it) |
| `build` / `test` / `clean` | Through the build tool                              |
| `exec <args>` | Run the wrapper with raw args, e.g. `:Sprout exec dependencies`  |
| `endpoints`   | Pick an HTTP endpoint                                            |
| `datasource`  | Add `spring.datasource` (+ `spring.jpa`) for the driver in your build |
| `config`      | Pick an `application*.yml/properties/conf`                       |
| `reload`      | Re-import Gradle/Maven now (every build file in the project)     |
| `jdk`         | Pick the project JDK (saved to `.idea/sprout.json`)              |
| `init`        | Create/open `.idea/sprout.json`                                  |
| `version`     | Show the installed version                                       |
| `info`        | Root, build tool, JDK and its source, the exact run command      |
| `unclutter`   | Delete existing Eclipse files (asks first) and reset the jdtls workspace |
| `wipe`        | Wipe the jdtls workspace and restart                             |

`:checkhealth sprout` lists JDKs, jdtls, Lombok and debug bundles.

## `.idea/sprout.json`

Everything is optional:

```json
{
  "jdk": "21",
  "profiles": ["dev"],
  "env": { "SERVER_PORT": "8081" },
  "envFile": ".env",
  "vmArgs": ["-Xmx1g"],
  "args": ["--debug"],
  "module": ":api",
  "reload": "ask",
  "jdtls": { "java": { "format": { "enabled": false } } }
}
```

`reload` is `ask` (default), `auto` or `never`: what happens when a build file changes.
`jdk` takes a major (`"21"`), an SDKMAN id (`"21.0.11-amzn"`) or a path. `module` is a Gradle
path (`:api`), a Maven module (`:api`), a bleep project or a Kotlin Toolchain module (`api`). An IntelliJ run configuration, when
you pick one, overrides profiles, env, main class and module and adds its VM/program args.

Classes with a `main` method (Java `static void main(`, Kotlin top-level `fun main(`, outside
`src/test`) are offered next to the run configurations, run in their own module. On Gradle a
non-Boot main class runs through a `sproutRun` task added by sprout's init script.

The file also pins the project root, which is useful in monorepos.

## Notes

- **Existing projects**: jdtls keeps using Eclipse files that already exist at the root, so run
  `:Sprout unclutter` once in projects that have them.
- jdtls' Gradle support (Buildship) can deadlock while reopening a workspace. sprout keeps Spring
  bundles out of jdtls' startup to avoid it and restarts jdtls once if it happens anyway; if it
  keeps happening, `:Sprout wipe` resets the workspace.
- For Gradle, JDT still compiles into `bin/`. Spring Initializr's `.gitignore` already ignores it.
- JVM args reach Gradle's `bootRun` through an init script in `stdpath("cache")`, so your
  `build.gradle` doesn't change.
- Spring Boot language server: `:MasonInstall vscode-spring-boot-tools`; it runs on JDK 21+ and
  uses about 1 GB of heap at most. Property completion that depends on your classpath starts once
  jdtls has imported the project, which requires opening a Java file. Turn it off with
  `opts = { spring_ls = { enabled = false } }`.
- Kotlin: language support comes from LazyVim's `lang.kotlin` extra, not jdtls. To run its
  server on the project JDK, give it `cmd_env = { JAVA_HOME = require("sprout").java_home() }`.
  Debugging needs `:MasonInstall kotlin-debug-adapter` (the `lang.kotlin` extra registers it
  too). In projects with Kotlin sources sprout uses it automatically; set
  `opts = { run = { debug_adapter = "java" } }` to use java-debug instead, e.g. in a mostly-Java
  project.
- Ktor: development mode (`-Dio.ktor.development=true`) is on for `run`/`debug`; turn it off
  with `opts = { ktor = { development = false } }`. For auto-reload, run `./gradlew -t build` in
  another terminal, as Ktor's docs describe.
- Kotlin Toolchain (`kotlin init`, formerly Amper): projects are found by `project.yaml` or a
  `module.yaml` with a `product:`, and run through the `./kotlin` wrapper (`kotlin run -m <module>
  --main-class … --jvm-args …`). `ktor: enabled` / `springBoot: enabled` turn on the Ktor and
  Spring features, and `settings.jvm.jdk.version` sets the project JDK. jdtls has no importer
  for these projects, so sprout gives it one: when jdtls starts, `kotlin show dependencies`
  resolves the dependencies in the background and sprout passes the jars (from the toolchain's
  cache) and each module's `src/`/`test/` to jdtls, so Java files get completion and
  diagnostics for libraries. Java code sees the project's Kotlin classes after a `kotlin build`
  or `run`. Saving a `module.yaml` re-resolves; `:Sprout reload` forces it. If you pass
  `--shared-cache-dir` to `kotlin`, set `opts = { kotlin_toolchain = { cache_dir = "…" } }`.
  The Spring Boot language server isn't started in these projects yet. Kotlin files get their
  completion from your Kotlin language server, which has to understand these projects itself.
- bleep: Java inside bleep builds is served by Metals over BSP. sprout handles run/compile/test.

## Versioning

Releases follow [semver](https://semver.org) and are tagged `vX.Y.Z`. With `version = "*"`,
lazy.nvim installs the latest release and `:Lazy update` moves between releases. Changes are
listed in [CHANGELOG.md](CHANGELOG.md).

To cut a release: set `M.version` in `lua/sprout/init.lua`, move the `Unreleased` entries in
`CHANGELOG.md` under the new version, commit, then `git tag vX.Y.Z && git push origin vX.Y.Z`.
The release workflow checks that the tag matches `M.version` and publishes the GitHub release
with that version's changelog section.

## License

[MIT](LICENSE)
