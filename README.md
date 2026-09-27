# sprout.nvim

Spring Boot and JVM projects in Neovim, without Eclipse files in your repo.

- **No clutter**: jdtls keeps `.project`, `.classpath`, `.settings/` and `.factorypath` in
  `stdpath("cache")/sprout/jdtls/<project>-<hash>`. Your project gets nothing new except
  `.idea/`, if you want it.
- **`.idea/` is the config**: reads `.idea/sprout.json`, IntelliJ's `.idea/misc.xml`
  (project JDK) and its Spring Boot / Application run configurations.
- **Right JDK per project** (SDKMAN, `/Library/Java`, `JAVA_HOME`), in this order:
  `.idea/sprout.json` → `.sdkmanrc` → `.idea/misc.xml` → build file (toolchain,
  `java.version`, …) → SDKMAN `current`. jdtls itself always runs on JDK 21+.
- **Lombok** out of the box (Mason's jar).
- **Build file changed → "Reload classpath?"**: save `pom.xml`, `build.gradle(.kts)` or
  `libs.versions.toml` (or `git pull` a change) and you're asked, like IntelliJ. Choose
  now / always / not now / never; always and never are saved per project. You get a notification
  when the re-import finishes, and new dependencies then show up in completion.
- **Spring Boot language server** (Mason's `vscode-spring-boot-tools`), started only in Spring
  Boot projects: completion, validation and hover in `application*.yml`/`.properties`
  (from your actual dependencies), `@Value("${…}")` completion, and Spring symbols. sprout connects
  it to jdtls for classpath and type information, the way VS Code does.
- **Completion tuned for Spring**: postfix templates, lazily resolved auto-imports, JUnit/
  AssertJ/Mockito/MockMvc static members, AWT/Swing/JDK internals filtered out.
- **Run / debug / build / test** via `gradlew`, `mvnw` or `bleep`, on the project JDK, with
  profiles, env, `.env` and JVM args. Debug starts the app with JDWP and attaches nvim-dap.
- **Endpoints picker**: every `@GetMapping`/`@PostMapping`/… in Java and Kotlin, with the
  class-level `@RequestMapping` prefix included.
- **Small**: ~1.5k lines of Lua, no background work until you open a Java file or run a command.

## Install (LazyVim)

Requires `lazyvim.plugins.extras.lang.java` and `dap.core`. sprout plugs into the java
extra's jdtls setup, so only one jdtls is started.

```lua
-- lua/plugins/sprout.lua
return {
  {
    "you/sprout.nvim",
    cmd = "Sprout",
    ft = { "java", "yaml", "jproperties" },
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
      { "<leader>jc", "<cmd>Sprout config<cr>", desc = "Spring config files" },
      { "<leader>ji", "<cmd>Sprout info<cr>", desc = "Project info" },
      { "<leader>jk", "<cmd>Sprout jdk<cr>", desc = "Pick project JDK" },
      { "<leader>ju", "<cmd>Sprout reload<cr>", desc = "Reload build config" },
    },
  },
  {
    "mfussenegger/nvim-jdtls",
    dependencies = { "you/sprout.nvim" },
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
| `run[!]`      | Run the app (`bootRun` / `spring-boot:run` / `bleep run`). `!` re-picks the run configuration |
| `debug[!]`    | Same, with JDWP on port 5005, and attaches nvim-dap once it's listening |
| `attach`      | Attach nvim-dap to port 5005                                     |
| `stop` / `restart` / `toggle` | Control the output terminal                      |
| `build` / `test` / `clean` | Through the build tool                              |
| `exec <args>` | Run the wrapper with raw args, e.g. `:Sprout exec dependencies`  |
| `endpoints`   | Pick an HTTP endpoint                                            |
| `config`      | Pick an `application*.yml/properties`                            |
| `reload`      | Re-import Gradle/Maven now (every build file in the project)     |
| `jdk`         | Pick the project JDK (saved to `.idea/sprout.json`)              |
| `init`        | Create/open `.idea/sprout.json`                                  |
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
path (`:api`), a Maven module (`:api`) or a bleep project. An IntelliJ run configuration, when
you pick one, overrides profiles, env, main class and module and adds its VM/program args.

The file also pins the project root, which is useful in monorepos.

## Notes

- **Existing projects**: jdtls keeps using Eclipse files that already exist at the root, so run
  `:Sprout unclutter` once in projects that have them.
- For Gradle, JDT still compiles into `bin/`. Spring Initializr's `.gitignore` already ignores it.
- JVM args reach Gradle's `bootRun` through an init script in `stdpath("cache")`, so your
  `build.gradle` doesn't change.
- Spring Boot language server: `:MasonInstall vscode-spring-boot-tools`; it runs on JDK 21+ and
  uses about 1 GB of heap at most. Property completion that depends on your classpath starts once
  jdtls has imported the project, which requires opening a Java file. Turn it off with
  `opts = { spring_ls = { enabled = false } }`.
- Kotlin: run/build/test/endpoints/JDK all work. Kotlin language support comes from LazyVim's
  `lang.kotlin` extra, not jdtls.
- bleep: Java inside bleep builds is served by Metals over BSP. sprout handles run/compile/test.
