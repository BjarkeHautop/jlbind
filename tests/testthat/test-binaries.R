test_that("use_jlbind_binaries() writes the release workflow", {
  expect_error(use_jlbind_binaries(withr::local_tempdir()), "No package found")
  pkg <- local_client()
  expect_message(file <- use_jlbind_binaries(pkg), "Wrote")
  expect_equal(file, file.path(pkg, ".github", "workflows", "binaries.yaml"))
  workflow <- readLines(file)
  expect_true(any(grepl("jlbind::build_binary(", workflow, fixed = TRUE)))
  expect_true(any(grepl("JLBIND_JULIAC:", workflow, fixed = TRUE)))
  expect_true(any(grepl("--draft", workflow, fixed = TRUE)))
  expect_true(any(grepl("actions/attest@", workflow, fixed = TRUE)))
  ignore <- readLines(file.path(pkg, ".Rbuildignore"))
  expect_true(all(c("^\\.github$", "^tools$") %in% ignore))
  expect_error(use_jlbind_binaries(pkg), "overwrite = TRUE")
})

# Mocks build_library() to write a fake private library into `out`.
local_fake_build <- function(target = "generic", env = parent.frame()) {
  local_mocked_bindings(
    build_library = function(packages, out, julia, cpu_target, private) {
      stopifnot(identical(cpu_target, target), isTRUE(private))
      dir.create(file.path(out, "jlbind-bundle", "lib"), recursive = TRUE)
      writeLines("lib", file.path(out, .library_file()))
      writeLines("blas", file.path(out, "jlbind-bundle", "lib", "libblas.so"))
      # Julia's artifacts are copied read-only.
      artifact <- file.path(out, "jlbind-bundle", "share", "artifact.so")
      dir.create(dirname(artifact))
      writeLines("artifact", artifact)
      Sys.chmod(artifact, "444")
      file.path(out, .library_file())
    },
    .env = env
  )
}

test_that("build_binary() builds, prunes and archives a private library", {
  pkg <- local_client()
  local_fake_build()
  withr::local_envvar(JLBIND_JULIAC = "x")
  # Stripping the fake library would fail.
  local_mocked_bindings(Sys.which = function(names) "", .package = "base")
  out <- withr::local_tempdir()
  pruned <- NULL
  expect_message(
    archive <- build_binary(
      pkg,
      out,
      prune = function(dir) {
        pruned <<- dir
        unlink(file.path(dir, "jlbind-bundle", "lib", "libblas.so"))
        unlink(file.path(dir, "jlbind-bundle", "share"), recursive = TRUE)
      },
      check = FALSE
    ),
    "SHA-256 hash [0-9a-f]{64}"
  )
  p <- .platform()
  expect_equal(
    basename(archive),
    paste0("demo_0.1.0_", p[["OS"]], "-", p[["Arch"]], ".tar.gz")
  )
  expect_equal(basename(pruned), sub("\\.tar\\.gz$", "", basename(archive)))
  files <- utils::untar(archive, list = TRUE)
  expect_true(any(grepl(.library_file(), files, fixed = TRUE)))
  expect_false(any(grepl("libblas", files, fixed = TRUE)))
  expect_false(any(grepl("artifact", files, fixed = TRUE)))

  # A prune script's value is the function.
  script <- withr::local_tempfile(fileext = ".R")
  writeLines("function(dir) unlink(file.path(dir, 'jlbind.so'))", script)
  local_mocked_bindings(.library_file = function() "jlbind.so")
  expect_error(
    suppressMessages(build_binary(pkg, out, prune = script, check = FALSE)),
    "removed the library itself"
  )
  expect_error(build_binary(pkg, out, prune = 1), "must be a function")
})

test_that("build_binary() passes on its CPU target, and warns of \"native\"", {
  pkg <- local_client()
  target <- "generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1)"
  local_fake_build(target)
  withr::local_envvar(JLBIND_JULIAC = "x")
  local_mocked_bindings(Sys.which = function(names) "", .package = "base")
  out <- withr::local_tempdir()
  msgs <- testthat::capture_messages(
    build_binary(pkg, out, check = FALSE, cpu_target = target)
  )
  expect_false(any(grepl("may crash", msgs, fixed = TRUE)))

  local_fake_build("native")
  local_mocked_bindings(.cpu_model = function(...) "This CPU")
  msgs <- testthat::capture_messages(
    build_binary(pkg, out, check = FALSE, cpu_target = "native")
  )
  expect_true(any(grepl("other than this one (This CPU)", msgs, fixed = TRUE)))
})

test_that("build_binary() needs a JuliaC that can privatize on Windows", {
  pkg <- local_client()
  withr::local_envvar(JLBIND_JULIAC = "")
  local_mocked_bindings(.platform = function() {
    c(OS = "Windows", Arch = "x86_64")
  })
  expect_error(build_binary(pkg), "Set JLBIND_JULIAC")
})

test_that("record_binaries() lists a release's libraries with their hashes", {
  pkg <- local_client()
  desc <- file.path(pkg, "DESCRIPTION")
  writeLines(
    c(readLines(desc), "URL: https://example.com, https://github.com/me/demo"),
    desc
  )
  archives <- c(
    Linux = fake_archive("demo", "0.1.0"),
    Windows = fake_archive("demo", "0.1.0")
  )
  args <- NULL
  local_mocked_bindings(.gh_download = function(repo, tag, pattern, dir) {
    args <<- list(repo = repo, tag = tag, pattern = pattern)
    for (os in names(archives)) {
      file.copy(
        archives[[os]],
        file.path(dir, paste0("demo_0.1.0_", os, "-x86_64.tar.gz"))
      )
    }
    0L
  })
  expect_message(file <- record_binaries(pkg), "Linux \\(x86_64\\), Windows")
  expect_equal(
    args,
    list(repo = "me/demo", tag = "v0.1.0", pattern = "demo_0.1.0_*.tar.gz")
  )
  b <- .binaries("demo", file)
  expect_equal(b$OS, c("Linux", "Windows"))
  expect_equal(b$Version, c("0.1.0", "0.1.0"))
  expect_equal(
    b$URL[[1L]],
    "https://github.com/me/demo/releases/download/v0.1.0/demo_0.1.0_Linux-x86_64.tar.gz"
  )
  expect_equal(b$SHA256, unname(vapply(archives, .sha256, "")))

  # An archive of another version is refused.
  archives <- c(Linux = fake_archive("demo", "0.0.9"))
  expect_error(record_binaries(pkg), "not the installed version 0.1.0")
})

test_that("JuliaC from JLBIND_JULIAC is passed to the build and recorded", {
  build <- list(
    jlbind = as.character(utils::packageVersion("jlbind")),
    Develop = ""
  )
  withr::local_envvar(JLBIND_JULIAC = "")
  expect_length(.build_reasons(build, NA), 0L)
  withr::local_envvar(JLBIND_JULIAC = "https://example.com/JuliaC.jl#pr")
  expect_match(
    .build_reasons(build, NA),
    "built with JuliaC 0.3, not https://example.com/JuliaC.jl#pr"
  )
  build$JuliaC <- "https://example.com/JuliaC.jl#pr"
  expect_length(.build_reasons(build, NA), 0L)
  # A library built with another JuliaC is kept without JLBIND_JULIAC.
  withr::local_envvar(JLBIND_JULIAC = "")
  expect_length(.build_reasons(build, NA), 0L)
})

test_that("private libraries on Windows point to a JuliaC that supports them", {
  withr::local_envvar(JLBIND_JULIAC = "")
  expect_message(.windows_private_message(windows = TRUE), "JLBIND_JULIAC")
  expect_silent(.windows_private_message(windows = FALSE))
  withr::local_envvar(JLBIND_JULIAC = "x")
  expect_silent(.windows_private_message(windows = TRUE))
})
