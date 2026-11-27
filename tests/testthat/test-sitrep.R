# A library directory as .build() leaves it, for the clients in `built` (a
# .client_table()), built with `julia`.
# A library built from the clients `built`, in `dir`; a private one with the
# salt `private`.
fake_library <- function(
  built,
  julia = "1.14.0",
  bindir = R.home(),
  dir = NULL,
  private = ""
) {
  if (is.null(dir)) {
    dir <- withr::local_tempdir(.local_envir = parent.frame())
  }
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
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
      ABI = .library_abi,
      Julia = julia,
      Built = "2026-10-01 12:00:00 UTC",
      Trim = TRUE,
      Develop = "",
      Private = private
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

test_that("a library for another CPU target, or another CPU, is stale", {
  clients <- fake_clients()
  dir <- fake_library(clients)
  build <- read.dcf(file.path(dir, "build"))
  write.dcf(
    cbind(build, CpuTarget = "native", CPU = "Old CPU"),
    file.path(dir, "build")
  )
  local_mocked_bindings(.cpu_model = function(...) "Old CPU")
  expect_equal(.stale_reasons(dir, clients, NA, "native"), character())
  expect_equal(
    .stale_reasons(dir, clients, NA, "generic"),
    "built for CPU target \"native\", not \"generic\""
  )
  local_mocked_bindings(.cpu_model = function(...) "New CPU")
  expect_equal(
    .stale_reasons(dir, clients, NA),
    "built for another CPU (Old CPU, not New CPU)"
  )
})

test_that("a library built with other Julia arguments is stale", {
  clients <- fake_clients()
  dir <- fake_library(clients)
  expect_equal(.stale_reasons(dir, clients, NA, NA, character()), character())
  expect_equal(
    .stale_reasons(dir, clients, NA, NA, c("-O3", "-g1")),
    "built with Julia arguments \"\", not \"-O3 -g1\""
  )
  build <- read.dcf(file.path(dir, "build"))
  write.dcf(cbind(build, JuliaArgs = "-O3 -g1"), file.path(dir, "build"))
  expect_equal(
    .stale_reasons(dir, clients, NA, NA, c("-O3", "-g1")),
    character()
  )
  expect_equal(
    .stale_reasons(dir, clients, NA, NA, character()),
    "built with Julia arguments \"-O3 -g1\", not \"\""
  )
  # Not compared unless asked for.
  expect_equal(.stale_reasons(dir, clients, NA), character())
})

test_that("only a native library on a known other CPU is a mismatch", {
  native <- list(CpuTarget = "native", CPU = "A")
  expect_match(
    .cpu_mismatch(native, "B"),
    "built for another CPU (A, not B)",
    fixed = TRUE
  )
  expect_null(.cpu_mismatch(native, "A"))
  expect_null(.cpu_mismatch(native, NA))
  expect_null(.cpu_mismatch(list(CpuTarget = "generic", CPU = "A"), "B"))
  expect_null(.cpu_mismatch(list(CpuTarget = "native", CPU = ""), "B"))
  expect_null(.cpu_mismatch(NULL, "B"))
  # With a generic fallback, it runs anywhere.
  expect_null(
    .cpu_mismatch(list(CpuTarget = "generic;native,clone_all", CPU = "A"), "B")
  )
  expect_match(
    .cpu_mismatch(list(CpuTarget = "native;generic", CPU = "A"), "B"),
    "another CPU"
  )
})

test_that("only a target based on \"native\" is native only", {
  expect_true(.native_only("native"))
  expect_true(.native_only(" native ,-avx512f;generic"))
  expect_false(.native_only("generic;native,clone_all"))
  expect_false(.native_only("x86-64-v3"))
  expect_false(.native_only("znver4"))
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
    package_version("1.12.6")
  })
  out <- capture.output({
    report <- jlbind_sitrep("my/julia")
  })
  expect_false(report$julia$ok)
  expect_match(out, "needs Julia >= 1.13", all = FALSE)
  expect_match(out, "built with Julia 1.14.0, not 1.12.6", all = FALSE)
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

test_that("a bundle is stale only for `bundle`, not for the installed Julia", {
  clients <- fake_clients()
  dir <- fake_library(clients)
  expect_equal(.stale_reasons(dir, clients, NA, NA, NULL, FALSE), character())
  expect_equal(
    .stale_reasons(dir, clients, NA, NA, NULL, TRUE),
    "not built as a bundle"
  )
  expect_equal(
    .stale_reasons(dir, clients, "1.14.1"),
    "built with Julia 1.14.0, not 1.14.1"
  )
  build <- read.dcf(file.path(dir, "build"))
  write.dcf(cbind(build, Bundle = "TRUE"), file.path(dir, "build"))
  expect_equal(.stale_reasons(dir, clients, NA, NA, NULL, TRUE), character())
  expect_equal(
    .stale_reasons(dir, clients, NA, NA, NULL, FALSE),
    "built as a bundle"
  )
  expect_equal(.stale_reasons(dir, clients, "1.14.1"), character())
})

test_that("a stale library from install_library() is rebuilt with it", {
  local_state()
  withr::local_envvar(
    R_USER_CACHE_DIR = withr::local_tempdir(),
    R_USER_CONFIG_DIR = withr::local_tempdir(),
    JLBIND_LIBRARY = NA
  )
  clients <- fake_clients(c("a", "b"))
  shared <- fake_library(clients[1, ], dir = .library_dir())
  .write_private("b")
  fake_library(clients[2, ], "1.14.1", dir = .private_dir("b"), private = "jlb")
  local_mocked_bindings(
    jlbind_clients = function(lib.loc = NULL) clients,
    .julia_version = function(julia) package_version("1.14.1"),
    .object_count = function(lib) 0
  )
  rebuild <- "Run jlbind::install_library() to rebuild the library"

  # The shared library is stale, and loaded, as once a client has bound to it.
  .state$dll <- list(name = "jlbind")
  .state$path <- file.path(shared, .library_file())
  out <- capture.output(jlbind_sitrep("my/julia"))
  expect_match(out, "built with Julia 1.14.0, not 1.14.1", all = FALSE)
  expect_match(
    out,
    paste0(rebuild, ", then restart R"),
    fixed = TRUE,
    all = FALSE
  )

  # Only the private library is stale.
  .state$dll <- NULL
  .state$path <- NULL
  fake_library(clients[1, ], "1.14.1", dir = shared)
  fake_library(clients[2, ], dir = .private_dir("b"), private = "jlb")
  out <- capture.output({
    report <- jlbind_sitrep("my/julia")
  })
  expect_equal(
    report$clients$library[[2]],
    file.path(.private_dir("b"), .library_file())
  )
  expect_match(out, rebuild, fixed = TRUE, all = FALSE)
  expect_no_match(out, "build_library()", fixed = TRUE)
})
