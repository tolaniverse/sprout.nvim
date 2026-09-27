# Changelog

All notable changes to sprout.nvim. Format: [Keep a Changelog](https://keepachangelog.com),
versions: [semver](https://semver.org).

## [Unreleased]

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

[Unreleased]: https://github.com/tolaniverse/sprout.nvim/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/tolaniverse/sprout.nvim/releases/tag/v0.1.0
