# Builds a pruned pre-built library of the test client hellojl with
# build_binary(), as the workflow use_jlbind_binaries() writes does, then
# installs it with install_library(method = "download") and calls it without
# Julia. It compiles a library, so it only runs when JLBIND_TEST_BINARY=true
# (the prebuilt.yaml workflow, run by hand, does so on Linux, macOS and
# Windows).

test_that("a pruned pre-built library is downloaded and runs without Julia", {
  skip_on_cran()
  skip_if_not(
    identical(Sys.getenv("JLBIND_TEST_BINARY"), "true"),
    "set JLBIND_TEST_BINARY=true to build a pre-built library"
  )
  skip_if_not_installed("callr")
  julia <- tryCatch(.find_julia(), error = function(e) NULL)
  skip_if(is.null(julia), "Julia >= 1.13 not found")
  # Released JuliaC can't privatize a runtime on Windows; JuliaC.jl#151 can.
  if (.Platform$OS.type == "windows" && !nzchar(.juliac())) {
    withr::local_envvar(JLBIND_JULIAC = .juliac_windows)
  }

  # The package author's side: a copy of hellojl with tests and a prune script.
  src <- file.path(withr::local_tempdir(), "hellojl")
  dir.create(src)
  file.copy(
    list.files(test_path("..", "clients", "hellojl"), full.names = TRUE),
    src,
    recursive = TRUE
  )
  fixtures <- test_path("fixtures", "prebuilt")
  dir.create(file.path(src, "tests", "testthat"), recursive = TRUE)
  file.copy(
    file.path(fixtures, "test-hellojl.R"),
    file.path(src, "tests", "testthat")
  )
  dir.create(file.path(src, "tools"))
  file.copy(
    file.path(fixtures, "prune-binary.R"),
    file.path(src, "tools", "prune-binary.R")
  )

  # build_binary() tests the library in a new R process, which needs this
  # jlbind installed.
  libpath <- local_install()
  withr::local_envvar(
    R_LIBS = paste(libpath, collapse = .Platform$path.sep)
  )
  out <- withr::local_tempdir()
  archive <- build_binary(
    src,
    out,
    prune = file.path(src, "tools", "prune-binary.R"),
    julia = julia
  )
  files <- utils::untar(archive, list = TRUE)
  expect_true(any(basename(files) == .library_file()))
  expect_false(any(grepl("jlbind-bundle/share/", files, fixed = TRUE)))

  # The release: the archive, listed with its hash in the package.
  url <- normalizePath(archive, winslash = "/")
  url <- paste0(if (startsWith(url, "/")) "file://" else "file:///", url)
  platform <- .platform()
  dir.create(file.path(src, "inst", "jlbind"))
  write.dcf(
    data.frame(
      Version = "0.1.0",
      OS = platform[["OS"]],
      Arch = platform[["Arch"]],
      URL = url,
      SHA256 = .sha256(archive)
    ),
    file.path(src, "inst", "jlbind", "binaries")
  )

  # The user's side, without Julia.
  libpath <- local_install(src)
  data <- withr::local_tempdir()
  sep <- .Platform$path.sep
  without_julia <- function(var) {
    dirs <- strsplit(Sys.getenv(var), sep, fixed = TRUE)[[1L]]
    paste(dirs[!grepl("julia", dirs, ignore.case = TRUE)], collapse = sep)
  }
  env <- c(
    callr::rcmd_safe_env(),
    R_USER_CACHE_DIR = data,
    R_USER_CONFIG_DIR = file.path(data, "config"),
    JULIA = "",
    JLBIND_JULIAC = "",
    PATH = without_julia("PATH"),
    LD_LIBRARY_PATH = without_julia("LD_LIBRARY_PATH"),
    DYLD_LIBRARY_PATH = without_julia("DYLD_LIBRARY_PATH")
  )
  installed <- callr::r(
    function() {
      suppressMessages(jlbind::install_library(
        "hellojl",
        method = "download",
        ask = FALSE
      ))
    },
    libpath = libpath,
    env = env,
    show = TRUE
  )
  expect_true(file.exists(installed))
  res <- callr::r(
    function() {
      library(hellojl)
      jlbind::check_bound("hellojl")
      maps <- if (file.exists("/proc/self/maps")) {
        readLines("/proc/self/maps")
      }
      report <- suppressMessages(jlbind::jlbind_sitrep())
      list(
        greet = greet("R"),
        julia = sub(".* ", "", maps[grepl("libjulia", maps, fixed = TRUE)]),
        private = report$private,
        again = tryCatch(
          {
            jlbind::install_library(method = "download", ask = FALSE)
            "downloaded"
          },
          message = conditionMessage
        )
      )
    },
    libpath = libpath,
    env = env,
    show = TRUE
  )
  expect_equal(res$greet, "Hello, R!")
  expect_length(res$private, 1L)
  expect_equal(res$private[[1L]]$problems, character())
  expect_equal(res$private[[1L]]$build$Download, url)
  expect_match(res$again, "up to date")
  # The Julia runtime is the library's own.
  if (length(res$julia)) {
    expect_true(all(startsWith(res$julia, normalizePath(data))))
  }
})
