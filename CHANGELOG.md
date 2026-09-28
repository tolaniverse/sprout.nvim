# Changelog

All notable changes to sprout.nvim. Format: [Keep a Changelog](https://keepachangelog.com),
versions: [semver](https://semver.org).

## [Unreleased]

### Changed

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

[Unreleased]: https://github.com/tolaniverse/sprout.nvim/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/tolaniverse/sprout.nvim/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/tolaniverse/sprout.nvim/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/tolaniverse/sprout.nvim/releases/tag/v0.1.0
