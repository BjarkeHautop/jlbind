# A library directory as .build() leaves it, for the clients in `built` (a
# .client_table()), built with `julia`.
fake_library <- function(built, julia = "1.14.0", bindir = R.home()) {
  dir <- withr::local_tempdir(.local_envir = parent.frame())
  file.create(file.path(dir, .library_file()))
  write.dcf(
    data.frame(
      Package = built$package,
      Version = built$version,
      Module = built$module,
      Hash = built$hash
    ),
    file.path(dir, "clients")
  )
  write.dcf(
    data.frame(
      jlbind = as.character(utils::packageVersion("jlbind")),
      Julia = julia,
      Built = "2026-10-01 12:00:00 UTC",
      Trim = TRUE,
      Develop = ""
    ),
    file.path(dir, "build")
  )
  writeLines(bindir, file.path(dir, "julia_bindir"))
  dir
}

test_that("each client's status says how the library stands for it", {
  clients <- fake_clients(c("a", "b", "c", "d", "e"))
  built <- data.frame(
    Package = c("a", "b", "c", "f"),
    Version = c("1.0", "0.9", "1.0", "1.0"),
    Hash = c("hash-a", "hash-b", "changed", "hash-f")
  )
  excluded <- data.frame(Package = "e", Version = "1.0", Hash = "hash-e")
  status <- .client_status(clients, built, excluded)
  expect_equal(status$package, c("a", "b", "c", "d", "e", "f"))
  expect_equal(
    status$status,
    c(
      "ok",
      "built for version 0.9",
      "Julia code changed",
      "not in the library",
      "left out",
      "not installed"
    )
  )
  expect_equal(status$built, c("1.0", "0.9", "1.0", NA, "1.0", "1.0"))
  expect_equal(status$version, c(rep("1.0", 5), NA))

  none <- .client_status(.client_table(list()), NULL, NULL)
  expect_equal(nrow(none), 0L)
})

test_that("a stale library says why", {
  clients <- fake_clients()
  dir <- fake_library(clients)
  expect_equal(.stale_reasons(dir, clients, "1.14.0"), character())
  expect_equal(
    .stale_reasons(dir, clients, "1.14.1"),
    "built with Julia 1.14.0, not 1.14.1"
  )
  # An unknown Julia version is not held against it.
  expect_equal(.stale_reasons(dir, clients, NA), character())
  clients$hash[[2]] <- "changed"
  expect_equal(
    .stale_reasons(dir, clients, "1.14.0"),
    "b: Julia code changed"
  )
  expect_equal(
    .stale_reasons(withr::local_tempdir(), clients, "1.14.0"),
    "it has not been built"
  )
})

test_that("jlbind_sitrep() reports on Julia, the library and its clients", {
  local_state()
  .state$dll <- NULL
  .state$path <- NULL
  .state$bound <- character()
  .state$problems <- list()
  clients <- fake_clients(c("a", "b"))
  dir <- fake_library(clients[1, ], bindir = file.path(tempdir(), "gone"))
  withr::local_envvar(
    JLBIND_LIBRARY = file.path(dir, .library_file()),
    JULIA_NUM_THREADS = "2"
  )
  local_mocked_bindings(
    jlbind_clients = function(lib.loc = NULL) clients,
    .julia_version = function(julia) package_version("1.14.0")
  )
  expect_output(
    {
      report <- jlbind_sitrep("my/julia")
    },
    "Julia 1.14.0 at my/julia"
  )
  expect_equal(report$julia$source, "argument")
  expect_true(report$julia$ok)
  expect_equal(report$library$how, "JLBIND_LIBRARY")
  expect_match(report$library$problems, "no longer exists")
  expect_equal(report$clients$status, c("ok", "not in the library"))
  expect_false(any(report$clients$bound))
  expect_equal(report$threads$count, 2L)
  expect_false(report$threads$fixed)

  writeLines(R.home(), file.path(dir, "julia_bindir"))
  expect_output({
    report <- jlbind_sitrep("my/julia")
  })
  expect_equal(report$library$problems, character())

  local_mocked_bindings(.julia_version = function(julia) {
    package_version("1.13.1")
  })
  out <- capture.output({
    report <- jlbind_sitrep("my/julia")
  })
  expect_false(report$julia$ok)
  expect_match(out, "needs Julia >= 1.14", all = FALSE)
  expect_match(out, "built with Julia 1.14.0, not 1.13.1", all = FALSE)
  expect_match(out, "jlbind::build_library()", fixed = TRUE, all = FALSE)
})

test_that("jlbind_sitrep() reports a missing Julia and library", {
  local_state()
  .state$dll <- NULL
  .state$path <- NULL
  withr::local_envvar(JLBIND_LIBRARY = file.path(tempdir(), "none.so"))
  local_mocked_bindings(
    jlbind_clients = function(lib.loc = NULL) fake_clients("a"),
    .locate_julia = function(julia) list(path = "", source = "PATH")
  )
  out <- capture.output({
    report <- jlbind_sitrep()
  })
  expect_true(is.na(report$julia$path))
  expect_false(report$library$exists)
  expect_equal(report$library$problems, "it has not been built")
  expect_match(out, "not found", all = FALSE)
  expect_match(out, "has not been built", all = FALSE)
})
