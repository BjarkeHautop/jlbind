# install_backend(), build_library() and .build() with the compile step and
# Julia mocked; test-integration.R runs them for real.

test_that("install_backend() builds only installed clients", {
  local_mocked_bindings(jlbind_clients = function(...) fake_clients())
  expect_error(
    install_backend(packages = c("a", "zz", "yy")),
    "Not an installed package that uses jlbind: zz, yy."
  )
  local_mocked_bindings(jlbind_clients = function(...) fake_clients()[0, ])
  expect_message(res <- install_backend(), "nothing to build")
  expect_null(res)
})

test_that("install_backend() leaves an up-to-date library alone", {
  dir <- withr::local_tempdir()
  bound <- FALSE
  local_mocked_bindings(
    jlbind_clients = function(...) fake_clients(),
    .backend_dir = function() dir,
    .up_to_date = function(dir, clients) TRUE,
    .bind_requested = function() {
      bound <<- TRUE
    },
    .build = function(...) stop("should not build")
  )
  expect_message(
    path <- install_backend(packages = "a"),
    "up to date"
  )
  expect_equal(path, file.path(dir, .library_file()))
  expect_true(bound)
})

test_that("install_backend() can be cancelled", {
  dir <- withr::local_tempdir()
  local_mocked_bindings(
    jlbind_clients = function(...) fake_clients(),
    .backend_dir = function() dir,
    .up_to_date = function(dir, clients) FALSE,
    .find_julia = function(julia) "julia",
    .build = function(...) stop("should not build")
  )
  local_mocked_bindings(menu = function(choices, title) 2L, .package = "utils")
  expect_message(res <- install_backend(ask = TRUE), "Cancelled")
  expect_null(res)
})

test_that("install_backend() replaces the old library and prunes stale ones", {
  local_state()
  root <- withr::local_tempdir()
  dir <- file.path(root, "backend")
  dir.create(dir)
  writeLines("old", file.path(dir, .library_file()))
  dir.create(file.path(root, "old-stale"))
  built <- NULL
  local_mocked_bindings(
    jlbind_clients = function(...) fake_clients(),
    .backend_dir = function() dir,
    .up_to_date = function(dir, clients) FALSE,
    .find_julia = function(julia) "julia",
    .bind_requested = function() NULL,
    .build = function(clients, out, julia, update, develop) {
      built <<- list(clients = clients$package, update = update)
      dir.create(out)
      writeLines("new", file.path(out, .library_file()))
    }
  )
  .state$dll <- NULL
  expect_message(
    path <- install_backend(ask = FALSE, update = TRUE),
    "^Built the compiled Julia library\\.\n$"
  )
  expect_equal(built, list(clients = c("a", "b"), update = TRUE))
  expect_equal(readLines(path), "new")
  expect_equal(list.files(root), "backend")

  # With a library loaded, the new one is used after a restart.
  .state$dll <- list(name = "jlbind")
  expect_message(install_backend(ask = FALSE, force = TRUE), "Restart R")
})

test_that("build_library() builds a source package into its .jlbind/", {
  pkg <- local_client()
  args <- NULL
  local_mocked_bindings(
    .find_julia = function(julia) "julia",
    .build = function(clients, out, julia, update, develop) {
      args <<- list(package = clients$package, out = out)
      dir.create(out)
    }
  )
  path <- build_library(pkg)
  expect_equal(args, list(package = "demo", out = file.path(pkg, ".jlbind")))
  expect_equal(
    path,
    file.path(normalizePath(file.path(pkg, ".jlbind")), .library_file())
  )
  expect_error(build_library(c(pkg, pkg)), "`out` is needed")
  expect_error(build_library("stats", tempfile()), "does not use jlbind")
})

test_that(".build() refuses two clients with the same binding package", {
  expect_error(
    .build(fake_clients(c("a", "b"), c("X", "X")), tempfile(), "julia", FALSE),
    "Two packages \\(a, b\\) have a Julia binding package named X"
  )
})

test_that(".build() passes its options to build.jl and records the build", {
  out <- withr::local_tempdir()
  checkout <- withr::local_tempdir()
  clients <- fake_clients(c("a", "b", "c"))
  clients$trim[[2]] <- FALSE
  args <- NULL
  local_mocked_bindings(
    .julia_version = function(julia) package_version("1.13.1"),
    .run_julia = function(julia, a) {
      args <<- a
      file.create(file.path(out, .library_file()))
      writeLines("B\tA", file.path(out, "conflicts"))
      0L
    }
  )
  msgs <- capture_messages(
    .build(clients, out, "julia", update = TRUE, develop = checkout)
  )
  expect_match(msgs[[1]], "without --trim, because b set")
  expect_match(msgs[[2]], "b was left out")
  expect_true(all(c("--update", "--no-trim") %in% args))
  expect_true(
    shQuote(paste0("--develop=", normalizePath(checkout))) %in% args
  )
  expect_true(all(shQuote(clients$path) %in% args))

  expect_false(file.exists(file.path(out, "conflicts")))
  expect_equal(.read_clients(out)$Package, c("a", "c"))
  expect_equal(.read_excluded(out)$Conflicts, "a")
  build <- read.dcf(file.path(out, "build"))
  expect_equal(build[, "Julia"][[1]], "1.13.1")
  expect_equal(build[, "Trim"][[1]], "FALSE")
  expect_equal(build[, "Develop"][[1]], normalizePath(checkout))
})

test_that(".build() fails if build.jl does", {
  out <- withr::local_tempdir()
  local_mocked_bindings(.run_julia = function(julia, args) 1L)
  expect_error(
    .build(fake_clients(), out, "julia", FALSE),
    "Compiling the Julia library failed"
  )
})

test_that("Julia must be found and at least 1.13", {
  withr::local_envvar(JULIA = NA, PATH = "")
  expect_error(.find_julia(), "Julia was not found")
  withr::local_envvar(JULIA = "my/julia")
  local_mocked_bindings(.julia_version = function(julia) NA)
  expect_error(.find_julia(), "Could not run `my/julia --version`")
  local_mocked_bindings(.julia_version = function(julia) {
    package_version("1.12.4")
  })
  expect_error(.find_julia("old/julia"), "old/julia is version 1.12.4")
  local_mocked_bindings(.julia_version = function(julia) {
    package_version("1.13.0")
  })
  expect_equal(.find_julia(), "my/julia")
})

test_that("a missing julia has no version", {
  expect_true(is.na(.julia_version(file.path(tempdir(), "no-such-julia"))))
})
