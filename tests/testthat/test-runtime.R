test_that("JULIA_NUM_THREADS is read as a count or auto", {
  withr::local_envvar(JULIA_NUM_THREADS = NA)
  expect_equal(.julia_threads(), 1L)
  withr::local_envvar(JULIA_NUM_THREADS = "3")
  expect_equal(.julia_threads(), 3L)
  withr::local_envvar(JULIA_NUM_THREADS = "2,1")
  expect_equal(.julia_threads(), 2L)
  withr::local_envvar(JULIA_NUM_THREADS = "auto")
  expect_equal(.julia_threads(), parallel::detectCores())
  withr::local_envvar(JULIA_NUM_THREADS = "lots")
  expect_warning(n <- .julia_threads(), "Ignoring")
  expect_equal(n, 1L)
})

test_that("the library is JLBIND_LIBRARY, else a client's own, else the default", {
  installed <- file.path(.library_dir(), .library_file())
  withr::local_envvar(JLBIND_LIBRARY = NA)
  expect_null(.dev_library("stats"))
  expect_equal(.library_path("stats"), installed)
  local_mocked_bindings(.dev_library = function(pkg) "dev/lib")
  expect_equal(.library_path("demo"), "dev/lib")
  expect_equal(.library_path(), installed)
  withr::local_envvar(JLBIND_LIBRARY = "override/lib")
  expect_equal(.library_path("demo"), "override/lib")
})

test_that("a library is up to date only for the same clients, jlbind, Julia", {
  dir <- withr::local_tempdir()
  clients <- data.frame(package = c("a", "b"), version = c("1.0", "2.0"))
  expect_false(.up_to_date(dir, clients, "1.13.1"))
  file.create(file.path(dir, .library_file()))
  write.dcf(
    data.frame(
      Package = c("b", "a"),
      Version = c("2.0", "1.0"),
      Module = c("B", "A")
    ),
    file.path(dir, "clients")
  )
  write.dcf(
    data.frame(
      jlbind = as.character(utils::packageVersion("jlbind")),
      Julia = "1.13.1"
    ),
    file.path(dir, "build")
  )
  expect_true(.up_to_date(dir, clients, "1.13.1"))
  clients$version[[1]] <- "1.1"
  expect_false(.up_to_date(dir, clients, "1.13.1"))
  expect_false(.up_to_date(dir, clients[1, ], "1.13.1"))
  clients$version[[1]] <- "1.0"
  expect_false(.up_to_date(dir, clients, "1.13.2"))
  write.dcf(data.frame(jlbind = "0.0.0"), file.path(dir, "build"))
  expect_false(.up_to_date(dir, clients, "1.13.1"))
})

test_that("a library built with local checkouts is never up to date", {
  dir <- withr::local_tempdir()
  clients <- data.frame(package = "a", version = "1.0")
  file.create(file.path(dir, .library_file()))
  write.dcf(
    data.frame(Package = "a", Version = "1.0", Module = "A"),
    file.path(dir, "clients")
  )
  build <- function(develop) {
    write.dcf(
      data.frame(
        jlbind = as.character(utils::packageVersion("jlbind")),
        Julia = "1.13.1",
        Develop = develop
      ),
      file.path(dir, "build")
    )
  }
  build("")
  expect_true(.up_to_date(dir, clients, "1.13.1"))
  build("/some/checkout")
  expect_false(.up_to_date(dir, clients, "1.13.1"))
})

test_that("clients left out of a build count towards being up to date", {
  dir <- withr::local_tempdir()
  clients <- data.frame(package = c("a", "b"), version = c("1.0", "2.0"))
  file.create(file.path(dir, .library_file()))
  write.dcf(
    data.frame(Package = "a", Version = "1.0", Module = "A"),
    file.path(dir, "clients")
  )
  write.dcf(
    data.frame(
      jlbind = as.character(utils::packageVersion("jlbind")),
      Julia = "1.13.1"
    ),
    file.path(dir, "build")
  )
  expect_false(.up_to_date(dir, clients, "1.13.1"))
  write.dcf(
    data.frame(Package = "b", Version = "2.0", Conflicts = "a"),
    file.path(dir, "excluded")
  )
  expect_true(.up_to_date(dir, clients, "1.13.1"))
  expect_equal(.read_excluded(dir)$Conflicts, "a")
})

test_that("conflicts from build.jl are read by package name", {
  file <- withr::local_tempfile()
  clients <- data.frame(
    package = c("a", "b", "c"),
    module = c("A", "B", "C")
  )
  writeLines(c("B\tA,C", "C\t"), file)
  expect_equal(
    .read_conflicts(file, clients),
    list(b = c("a", "c"), c = character())
  )
  expect_equal(
    .read_conflicts(tempfile(), clients),
    setNames(list(), character())
  )
})

test_that("a left-out client is told what it conflicts with", {
  msg <- .excluded_message("b", "a", c("a", "b", "c"))
  expect_match(msg, "conflict with those of a", fixed = TRUE)
  expect_match(msg, 'install_library(packages = c("b", "c"))', fixed = TRUE)
  expect_match(.excluded_message("b", NULL, "b"), "cannot be resolved")
})

test_that("a missing or unloadable library is reported", {
  local_state()
  .state$dll <- NULL
  missing <- file.path(withr::local_tempdir(), .library_file())
  withr::local_envvar(JLBIND_LIBRARY = missing)
  expect_false(.load_library())
  expect_match(.state$problem, "has not been built", fixed = TRUE)
  expect_equal(.state$path, missing)

  writeLines("not a library", missing)
  expect_false(.load_library())
  expect_match(.state$problem, "could not be loaded", fixed = TRUE)

  # Once loaded, it is not looked for again.
  .state$dll <- list(name = "jlbind")
  expect_true(.load_library())
})

test_that("a client is bound only to a library built from its version", {
  local_state()
  .state$clients <- NULL
  .state$excluded <- NULL
  expect_null(.bind_problem("stats"))

  version <- as.character(getNamespaceVersion("stats"))
  .state$clients <- data.frame(Package = "stats", Version = version)
  expect_null(.bind_problem("stats"))
  .state$clients$Version <- "0.0.1"
  expect_match(
    .bind_problem("stats"),
    "built for stats 0.0.1, not",
    fixed = TRUE
  )

  .state$clients <- data.frame(Package = "a", Version = "1.0")
  expect_match(.bind_problem("stats"), "built without stats", fixed = TRUE)
  .state$excluded <- data.frame(Package = "stats", Conflicts = "a")
  expect_match(.bind_problem("stats"), "conflict with those of a", fixed = TRUE)
  .state$excluded$Conflicts <- ""
  expect_match(.bind_problem("stats"), "cannot be resolved", fixed = TRUE)
})

test_that("bind_client() records why a client could not be bound", {
  local_state()
  .state$dll <- list(name = "jlbind")
  .state$clients <- NULL
  .state$requested <- character()
  .state$bound <- character()
  .state$problems <- list()

  expect_error(check_bound("stats"), "has not asked to be bound")
  # stats has registered routines, but no jlbind_bind.
  expect_false(bind_client("stats"))
  expect_false(is_bound("stats"))
  expect_error(check_bound("stats"), "has no routine `jlbind_bind`")

  # A bound client is bound again, as load_all() reloads its DLL.
  .state$bound <- "stats"
  expect_false(bind_client("stats"))
  expect_false(is_bound("stats"))
  .state$bound <- "stats"
  expect_true(check_bound("stats"))

  # Without a library, the reason is that it could not be loaded.
  .state$dll <- NULL
  .state$bound <- character()
  .state$problem <- "No library."
  expect_error(check_bound("stats"), "No library.", fixed = TRUE)
})

# Writes what build_library() records for a library in `dir` built from the
# client in `src`.
fake_dev_library <- function(src, dir, version = NULL, hash = NULL) {
  client <- .client_info(src)
  dir.create(dir, showWarnings = FALSE)
  file.create(file.path(dir, .library_file()))
  write.dcf(
    data.frame(
      Package = client$package,
      Version = if (is.null(version)) client$version else version,
      Module = client$module,
      Hash = if (is.null(hash)) client$hash else hash
    ),
    file.path(dir, "clients")
  )
  write.dcf(
    data.frame(
      jlbind = as.character(utils::packageVersion("jlbind")),
      Julia = "1.14.0",
      Develop = "/some/checkout"
    ),
    file.path(dir, "build")
  )
}

test_that("a development library is out of date when its client changes", {
  src <- local_client()
  dir <- file.path(src, .dev_dir)
  stale <- function() {
    .dev_stale_reasons(
      src,
      .read_clients(dir),
      .read_build(dir),
      .read_excluded(dir)
    )
  }
  expect_length(stale(), 0L)
  fake_dev_library(src, dir)
  # Local checkouts are expected in development.
  expect_length(stale(), 0L)
  fake_dev_library(src, dir, hash = "old")
  expect_equal(stale(), "Julia code changed")
  fake_dev_library(src, dir, version = "0.0.1")
  expect_equal(stale(), "built for version 0.0.1")
})

test_that("an out-of-date development library is rebuilt before loading", {
  local_state()
  withr::local_envvar(JLBIND_LIBRARY = NA)
  src <- local_client()
  dir <- file.path(src, .dev_dir)
  fake_dev_library(src, dir, hash = "old")
  path <- file.path(dir, .library_file())
  local_mocked_bindings(.dev_library = function(pkg) path)
  built <- NULL
  local_mocked_bindings(build_library = function(packages, out, develop) {
    built <<- list(packages = packages, out = out, develop = develop)
  })

  .state$dll <- NULL
  expect_message(.refresh_dev_library("demo"), "Julia code changed")
  expect_equal(normalizePath(built$packages), normalizePath(src))
  expect_equal(normalizePath(built$out), normalizePath(dir))
  expect_equal(built$develop, "/some/checkout")

  built <- NULL

  # Once a library is loaded it cannot be replaced, and it is the loaded one
  # that is compared with the sources, though the one on disk is rebuilt.
  .state$dll <- list(name = "jlbind")
  .state$path <- path
  .state$clients <- .read_clients(dir)
  .state$build <- .read_build(dir)
  .state$excluded <- NULL
  fake_dev_library(src, dir)
  local_mocked_bindings(.rebuild_hint = function(pkg) "Restart R.")
  expect_warning(.refresh_dev_library("demo"), "Julia code changed")
  .state$clients <- .read_clients(dir)
  expect_silent(.refresh_dev_library("demo"))
  .state$clients$Hash <- "old"
  .state$path <- "elsewhere"
  expect_silent(.refresh_dev_library("demo"))
  expect_null(built)

  # A library built from other clients too is not rebuilt.
  .state$dll <- NULL
  fake_dev_library(src, dir, hash = "old")
  write.dcf(
    data.frame(Package = c("demo", "other"), Version = "0.1.0", Hash = "x"),
    file.path(dir, "clients")
  )
  expect_warning(.refresh_dev_library("demo"), "built from demo, other")
  expect_null(built)

  withr::local_envvar(JLBIND_LIBRARY = "override")
  expect_silent(.refresh_dev_library("demo"))
})

test_that("the advice to rebuild depends on the library loaded", {
  local_state()
  .state$path <- file.path(.library_dir(), .library_file())
  expect_match(.rebuild_hint("demo"), "install_library()", fixed = TRUE)

  .state$path <- "dev/.jlbind/lib"
  .state$clients <- data.frame(Package = "demo")
  local_mocked_bindings(.dev_library = function(pkg) "dev/.jlbind/lib")
  expect_match(.rebuild_hint("demo"), "load_all() again", fixed = TRUE)

  # Built from other clients too, so load_all() does not rebuild it.
  .state$clients <- data.frame(Package = c("demo", "other"))
  expect_match(.rebuild_hint("demo"), "build_library()", fixed = TRUE)
  .state$path <- "elsewhere/lib"
  expect_match(.rebuild_hint("demo"), "(elsewhere/lib)", fixed = TRUE)
})

test_that("clients that asked are bound once a library is built", {
  local_state()
  .state$requested <- c("stats", "jlbind.not.loaded", "utils")
  .state$bound <- "utils"
  asked <- character()
  local_mocked_bindings(bind_client = function(pkg) {
    asked <<- c(asked, pkg)
  })
  .bind_requested()
  expect_equal(asked, "stats")
})

test_that("on Windows, the recorded Julia bindir is put on the PATH once", {
  dir <- withr::local_tempdir()
  lib <- file.path(dir, .library_file())
  bindir <- withr::local_tempdir()
  withr::local_envvar(PATH = "C:\\Windows")
  .add_julia_bindir(lib, windows = TRUE)
  expect_equal(Sys.getenv("PATH"), "C:\\Windows")
  writeLines(bindir, file.path(dir, "julia_bindir"))
  .add_julia_bindir(lib, windows = FALSE)
  expect_equal(Sys.getenv("PATH"), "C:\\Windows")
  .add_julia_bindir(lib, windows = TRUE)
  path <- paste0(normalizePath(bindir), ";C:\\Windows")
  expect_equal(Sys.getenv("PATH"), path)
  .add_julia_bindir(lib, windows = TRUE)
  expect_equal(Sys.getenv("PATH"), path)
})

test_that("a binding package's hash follows its files", {
  dir <- withr::local_tempdir()
  dir.create(file.path(dir, "src"))
  writeLines('name = "X"', file.path(dir, "Project.toml"))
  writeLines("f(x) = x", file.path(dir, "src", "X.jl"))
  hash <- .binding_hash(dir)
  expect_equal(.binding_hash(dir), hash)
  writeLines("f(x, y) = x", file.path(dir, "src", "X.jl"))
  changed <- .binding_hash(dir)
  expect_false(identical(changed, hash))
  writeLines("g() = 1", file.path(dir, "src", "more.jl"))
  expect_false(identical(.binding_hash(dir), changed))
})

test_that("a library is out of date once a client's Julia code changes", {
  dir <- withr::local_tempdir()
  clients <- data.frame(package = "a", version = "1.0", hash = "h1")
  file.create(file.path(dir, .library_file()))
  write.dcf(
    data.frame(Package = "a", Version = "1.0", Module = "A", Hash = "h1"),
    file.path(dir, "clients")
  )
  write.dcf(
    data.frame(
      jlbind = as.character(utils::packageVersion("jlbind")),
      Julia = "1.13.1"
    ),
    file.path(dir, "build")
  )
  expect_true(.up_to_date(dir, clients, "1.13.1"))
  clients$hash <- "h2"
  expect_false(.up_to_date(dir, clients, "1.13.1"))
})
