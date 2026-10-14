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

  .state$bound <- "stats"
  expect_true(bind_client("stats"))
  expect_true(check_bound("stats"))

  # Without a library, the reason is that it could not be loaded.
  .state$dll <- NULL
  .state$bound <- character()
  .state$problem <- "No library."
  expect_error(check_bound("stats"), "No library.", fixed = TRUE)
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

test_that("library_info() lists the clients built, left out and bound", {
  clients <- .info_clients(
    data.frame(Package = c("a", "b"), Version = "1.0", Module = c("A", "B")),
    data.frame(Package = "c", Version = "2.0", Module = "C", Conflicts = "a"),
    "a"
  )
  expect_equal(
    clients,
    data.frame(
      package = c("a", "b", "c"),
      version = c("1.0", "1.0", "2.0"),
      module = c("A", "B", "C"),
      included = c(TRUE, TRUE, FALSE),
      bound = c(TRUE, FALSE, FALSE)
    )
  )

  # A library that records no clients lists those bound to it.
  clients <- .info_clients(NULL, NULL, "a")
  expect_equal(clients$package, "a")
  expect_equal(clients$version, NA_character_)
  expect_true(clients$bound)
  expect_equal(nrow(.info_clients(NULL, NULL, character())), 0L)
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
