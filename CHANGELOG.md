# Changelog

All notable changes to sprout.nvim. Format: [Keep a Changelog](https://keepachangelog.com),
versions: [semver](https://semver.org).

## [Unreleased]

## [0.3.0] - 2026-10-05

### Added

- `:Sprout run` / `debug` find classes with a `main` method and offer them alongside the IntelliJ
  run configurations; the picked class runs in its own module on Gradle, Maven and bleep. IntelliJ
  Application configurations' main class is now honoured on Gradle too.

- Ktor support: routes from the routing DSL (nested `route` blocks, `webSocket`/`sse`,
  type-safe `get<Resource>` resolved through `@Resource` classes) show up in `:Sprout endpoints`;
  `:Sprout run`/`debug` use the `run` task with Ktor development mode on (`ktor.development`);
  Maven projects whose `exec-maven-plugin` sets a `<mainClass>` run without picking one;
  `:Sprout config` lists `application*.conf`.
- Kotlin: `:Sprout debug`/`attach` use Mason's `kotlin-debug-adapter` in projects with Kotlin
  sources (`run.debug_adapter` overrides); `suspend fun main` and `@file:JvmName` are honoured
  when finding main classes; the project JDK is also read from Kotlin's `jvmTarget`.
- Kotlin Toolchain (`kotlin init`, formerly Amper) projects: found by `project.yaml` /
  `module.yaml`, and run/debug/build/test/clean go through the `./kotlin` wrapper (modules,
  main class, JVM args and app args included). Ktor and Spring Boot are detected from
  `ktor: enabled` / `springBoot: enabled`, and the project JDK from `settings.jvm.jdk.version`.
- jdtls works in Kotlin Toolchain projects: sprout resolves the dependencies with
  `kotlin show dependencies` and hands jdtls the jars and module source folders, so Java files
  get library completion and diagnostics. Re-resolved when a `module.yaml` is saved and on
  `:Sprout reload`; `:Sprout info` shows the jar count.
- `:Sprout info` shows the stack (Spring Boot, Ktor, Kotlin/Java); `:checkhealth sprout` checks
  for kotlin-debug-adapter.

### Changed

- A main class picked from the root module of a multi-project Gradle build runs in the root
  project only (`:run`), not in every subproject.
- `:Sprout stop` also closes the output pane (the output is kept; `:Sprout toggle` reopens it).

## [0.2.1] - 2026-09-27

### Fixed

- jdtls could hang on startup in Gradle projects when reopening an existing workspace (Buildship
  "Unable to acquire the state change lock"), leaving Java and `application.yml` completion
  dead. Spring Boot Tools' jdtls bundles require Buildship; they are no longer started during
  jdtls' initialize but loaded with `java.reloadBundles` once jdtls is ready.
- If jdtls still hits that Buildship lock, sprout restarts it once and says so.

## [0.2.0] - 2026-09-27

### Added

- `:Sprout datasource`: writes `spring.datasource` (and `spring.jpa` with Data JPA) for the JDBC
  driver in your build (PostgreSQL, MySQL, MariaDB, H2, SQL Server, Oracle) into
  `application.yml` or `.properties`, with `${DB_URL:…}`-style placeholders. Merges under an
  existing `spring:` key, follows the file's indent, never overwrites an existing datasource.
- MIT license.

### Fixed

- Property completion in `application.yml`/`.properties` was empty when the file was opened
  before any Java file: jdtls (the Spring language server's classpath source) now starts from a
  hidden buffer holding the `@SpringBootApplication` class.

## [0.1.0] - 2026-09-27

### Added

- jdtls setup that keeps `.project`, `.classpath`, `.settings/` and `.factorypath` out of the
  project (workspace under `stdpath("cache")/sprout/jdtls`, one per project root).
- Per-project JDK from `.idea/sprout.json`, `.sdkmanrc`, `.idea/misc.xml` or the build file,
  across SDKMAN, `/Library/Java` and `JAVA_HOME`; jdtls itself runs on JDK 21+.
- Lombok via Mason's jar.
- `.idea/sprout.json` settings and IntelliJ Spring Boot / Application run configurations.
- `:Sprout run|debug|build|test|clean|exec` through Gradle, Maven or bleep, on the project JDK,
  with profiles, env, `.env` and JVM args; debug attaches nvim-dap.
- "Reload classpath?" prompt when `pom.xml` / `build.gradle(.kts)` / `libs.versions.toml`
  change, with per-project always/never, and `:Sprout reload`.
- Spring Boot language server (Mason `vscode-spring-boot-tools`) bridged to jdtls:
  `application*.yml`/`.properties` completion, validation and hover, `@Value` completion.
- Endpoints and Spring config file pickers.
- Completion tuned for Spring (postfix, lazy text edits, static member favourites, filtered types).
- `:Sprout unclutter` to remove old Eclipse files, `:Sprout info`, `:Sprout jdk`,
  `:checkhealth sprout`.
- LazyVim integration through the java extra's nvim-jdtls options.

[Unreleased]: https://github.com/tolaniverse/sprout.nvim/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/tolaniverse/sprout.nvim/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/tolaniverse/sprout.nvim/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/tolaniverse/sprout.nvim/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/tolaniverse/sprout.nvim/releases/tag/v0.1.0
