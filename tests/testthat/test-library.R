# install_library(), build_library() and .build() with the compile step and
# Julia mocked; test-integration.R runs them for real.

test_that("install_library() builds only installed clients", {
  local_mocked_bindings(jlbind_clients = function(...) fake_clients())
  expect_error(
    install_library(packages = c("a", "zz", "yy")),
    "Not an installed package that uses jlbind: zz, yy."
  )
  local_mocked_bindings(jlbind_clients = function(...) fake_clients()[0, ])
  expect_message(res <- install_library(), "nothing to build")
  expect_null(res)
})

test_that("install_library() leaves an up-to-date library alone", {
  dir <- withr::local_tempdir()
  bound <- FALSE
  local_mocked_bindings(
    jlbind_clients = function(...) fake_clients(),
    .library_dir = function() dir,
    .up_to_date = function(dir, clients, julia) TRUE,
    .find_julia = function(julia) "julia",
    .julia_version = function(julia) package_version("1.13.1"),
    .bind_requested = function() {
      bound <<- TRUE
    },
    .build = function(...) stop("should not build")
  )
  expect_message(
    path <- install_library(packages = "a"),
    "up to date"
  )
  expect_equal(path, file.path(dir, .library_file()))
  expect_true(bound)
})

test_that("install_library() can be cancelled", {
  dir <- withr::local_tempdir()
  local_mocked_bindings(
    jlbind_clients = function(...) fake_clients(),
    .library_dir = function() dir,
    .up_to_date = function(dir, clients, julia) FALSE,
    .find_julia = function(julia) "julia",
    .julia_version = function(julia) package_version("1.13.1"),
    .build = function(...) stop("should not build")
  )
  local_mocked_bindings(menu = function(choices, title) 2L, .package = "utils")
  expect_message(res <- install_library(ask = TRUE), "Cancelled")
  expect_null(res)
})

test_that("install_library() replaces the old library and prunes stale ones", {
  local_state()
  root <- withr::local_tempdir()
  dir <- file.path(root, "library")
  dir.create(dir)
  writeLines("old", file.path(dir, .library_file()))
  dir.create(file.path(root, "old-stale"))
  # Another session's build in progress, and a file that is not a build.
  dir.create(file.path(root, "build-other"))
  writeLines("keep", file.path(root, "notes"))
  built <- NULL
  local_mocked_bindings(
    jlbind_clients = function(...) fake_clients(),
    .library_dir = function() dir,
    .up_to_date = function(dir, clients, julia) FALSE,
    .find_julia = function(julia) "julia",
    .julia_version = function(julia) package_version("1.13.1"),
    .bind_requested = function() NULL,
    .build = function(clients, out, julia, versions, develop) {
      built <<- list(clients = clients$package, versions = versions)
      dir.create(out)
      writeLines("new", file.path(out, .library_file()))
    }
  )
  .state$dll <- NULL
  expect_message(
    path <- install_library(ask = FALSE, versions = "compat"),
    "^Built the compiled Julia library\\.\n$"
  )
  expect_equal(built, list(clients = c("a", "b"), versions = "compat"))
  expect_equal(readLines(path), "new")
  expect_equal(list.files(root), c("build-other", "library", "notes"))

  # With a library loaded, the new one is used after a restart.
  .state$dll <- list(name = "jlbind")
  expect_message(install_library(ask = FALSE, force = TRUE), "Restart R")
})

test_that("install_library() keeps the old library if the new one fails", {
  local_state()
  root <- withr::local_tempdir()
  dir <- file.path(root, "library")
  dir.create(dir)
  writeLines("old", file.path(dir, .library_file()))
  local_mocked_bindings(
    jlbind_clients = function(...) fake_clients(),
    .library_dir = function() dir,
    .up_to_date = function(dir, clients, julia) FALSE,
    .find_julia = function(julia) "julia",
    .julia_version = function(julia) package_version("1.13.1"),
    # Builds nothing, so there is nothing to move into place.
    .build = function(clients, out, julia, versions, develop) NULL
  )
  expect_error(
    expect_warning(install_library(ask = FALSE), "cannot rename"),
    "Could not move the library"
  )
  expect_equal(readLines(file.path(dir, .library_file())), "old")
  expect_equal(list.files(root), "library")
})

test_that("remove_library() deletes the library and the builds next to it", {
  local_state()
  root <- file.path(withr::local_tempdir(), "jlbind")
  dir <- file.path(root, "library")
  dir.create(dir, recursive = TRUE)
  dir.create(file.path(root, "old-a"))
  file.create(file.path(dir, .library_file()))
  local_mocked_bindings(.library_dir = function() dir)

  local_mocked_bindings(menu = function(choices, title) 2L, .package = "utils")
  expect_message(res <- remove_library(ask = TRUE), "Cancelled")
  expect_false(res)
  expect_true(dir.exists(dir))

  expect_message(
    res <- remove_library(ask = FALSE),
    "^Removed the compiled Julia library\\.\n$"
  )
  expect_true(res)
  expect_false(dir.exists(root))

  expect_message(
    res <- remove_library(ask = FALSE),
    "no compiled Julia library"
  )
  expect_false(res)
})

test_that("remove_library() says a loaded library goes on working", {
  local_state()
  dir <- file.path(withr::local_tempdir(), "library")
  dir.create(dir)
  local_mocked_bindings(.library_dir = function() dir)
  .state$path <- file.path(dir, .library_file())
  if (.Platform$OS.type == "windows") {
    expect_error(remove_library(ask = FALSE), "Restart R")
    expect_true(dir.exists(dir))
  } else {
    expect_message(remove_library(ask = FALSE), "keep working")
  }
})

test_that("only old libraries and abandoned builds are pruned", {
  root <- withr::local_tempdir()
  for (d in c("old-a", "build-new", "build-abandoned", "library")) {
    dir.create(file.path(root, d))
  }
  writeLines("keep", file.path(root, "notes"))
  now <- Sys.time()
  Sys.setFileTime(file.path(root, "build-abandoned"), now - 2 * 86400)
  .prune_builds(root, now)
  expect_equal(list.files(root), c("build-new", "library", "notes"))
})

test_that("build_library() builds a source package into its .jlbind/", {
  pkg <- local_client()
  args <- NULL
  local_mocked_bindings(
    .find_julia = function(julia) "julia",
    .build = function(clients, out, julia, versions, develop) {
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
  expect_error(build_library("demo"), "`out` is needed")
})

test_that("build_library() tells paths from package names by their form", {
  expect_equal(
    .is_path(c(".", "..", "./pkg", "a/b", "pkg", "pkg.name")),
    c(TRUE, TRUE, TRUE, TRUE, FALSE, FALSE)
  )
})

test_that(".build() refuses two clients with the same binding package", {
  expect_error(
    .build(fake_clients(c("a", "b"), c("X", "X")), tempfile(), "julia"),
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
    .build(clients, out, "julia", versions = "compat", develop = checkout)
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

test_that("Julia must be found and at least 1.14", {
  withr::local_envvar(JULIA = NA, PATH = "")
  expect_error(.find_julia(), "Julia was not found")
  withr::local_envvar(JULIA = "my/julia")
  local_mocked_bindings(.julia_version = function(julia) NA)
  expect_error(.find_julia(), "Could not run `my/julia --version`")
  local_mocked_bindings(.julia_version = function(julia) {
    package_version("1.13.1")
  })
  expect_error(.find_julia("old/julia"), "old/julia is version 1.13.1")
  local_mocked_bindings(.julia_version = function(julia) {
    package_version("1.14.0")
  })
  expect_equal(.find_julia(), "my/julia")
})

test_that("a missing julia has no version", {
  expect_true(is.na(.julia_version(file.path(tempdir(), "no-such-julia"))))
})
