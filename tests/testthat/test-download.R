# Has `pkg` offer the pre-built library `archive` with hash `sha256`.
local_offer <- function(
  archive,
  sha256 = .sha256(archive),
  version = "1.0",
  env = parent.frame()
) {
  url <- paste0(
    "file://",
    if (windows) "/",
    normalizePath(archive, "/", mustWork = FALSE)
  )
  local_mocked_bindings(
    .binaries = function(pkg) {
      p <- .platform()
      data.frame(
        Version = version,
        OS = p[["OS"]],
        Arch = p[["Arch"]],
        URL = url,
        SHA256 = sha256
      )
    },
    .env = env
  )
  url
}

local_download_env <- function(env = parent.frame()) {
  withr::local_envvar(
    R_USER_CACHE_DIR = withr::local_tempdir(.local_envir = env),
    R_USER_CONFIG_DIR = withr::local_tempdir(.local_envir = env),
    .local_envir = env
  )
  local_state(env)
  local_mocked_bindings(
    jlbind_clients = function(...) fake_clients(),
    .env = env
  )
}

installed_dir <- function(pkg = "a") {
  .private_dir(pkg)
}

test_that("method = 'download' installs a pre-built library it has checked", {
  local_download_env()
  url <- local_offer(fake_archive())
  expect_message(
    path <- install_library("a", ask = FALSE, method = "download"),
    "Installed the pre-built Julia library of a"
  )
  dir <- installed_dir()
  expect_equal(path, file.path(dir, .library_file()))
  expect_true(file.exists(path))
  build <- .read_build(dir)
  expect_equal(unname(build$Download), url)
  expect_true(.is_downloaded(build))
  expect_equal(.read_clients(dir)$Version, "1.0")
  # Recorded as private, so that the client binds to it.
  expect_equal(.read_private(), "a")
  expect_equal(.library_path("a"), path)
  # No leftover download or unpacked archive next to it.
  expect_length(list.files(dirname(dir), "^(build|old)-"), 0L)
  expect_equal(.downloaded_packages(c("a", "b")), "a")

  expect_message(
    install_library("a", ask = FALSE, method = "download"),
    "up to date"
  )
  expect_message(
    install_library("a", ask = FALSE, force = TRUE, method = "download"),
    "Installed"
  )
})

test_that("a download whose hash differs is not installed", {
  local_download_env()
  local_offer(fake_archive(), sha256 = strrep("0", 64L))
  expect_error(
    install_library("a", ask = FALSE, method = "download"),
    "is not the one a lists \\(its SHA-256 hash is [0-9a-f]{64}, not 0{64}\\)"
  )
  expect_false(dir.exists(installed_dir()))
})

test_that("a pre-built library for something else is not installed", {
  local_download_env()
  expect_rejected <- function(archive, msg) {
    local_offer(archive)
    expect_error(install_library("a", ask = FALSE, method = "download"), msg)
    expect_false(dir.exists(installed_dir()))
  }
  expect_rejected(
    fake_archive(version = "0.9"),
    "not the installed version 1.0"
  )
  expect_rejected(fake_archive(pkg = "b"), "built without a")
  expect_rejected(fake_archive(abi = 0L), "version 0 of jlbind's interface")
  expect_rejected(fake_archive(abi = NA), "an older version")
  expect_rejected(fake_archive(bundle = FALSE), "no Julia runtime of its own")
  expect_rejected(fake_archive(salt = ""), "no private Julia runtime \\(build")
})

test_that("a pre-built library listed for another version isn't downloaded", {
  local_download_env()
  local_offer(
    file.path(tempdir(), "nonexistent.tar.gz"),
    strrep("a", 64),
    "0.9"
  )
  expect_error(
    install_library("a", ask = FALSE, method = "download"),
    "a 1.0 lists a pre-built library for version 0.9 only. Install a released"
  )
  expect_message(
    res <- install_library(ask = FALSE, method = "download"),
    "a 1.0 lists .*; b 1.0 lists"
  )
  expect_null(res)
})

test_that("packages without a pre-built library are skipped or refused", {
  local_download_env()
  local_mocked_bindings(.binaries = function(pkg) {
    data.frame(
      Version = "1.0",
      OS = "Plan9",
      Arch = "mips",
      URL = "x",
      SHA256 = strrep("a", 64)
    )
  })
  expect_error(
    install_library("a", ask = FALSE, method = "download"),
    "a offers no pre-built library for"
  )
  expect_message(
    res <- install_library(ask = FALSE, method = "download"),
    "a, b offer no pre-built library"
  )
  expect_null(res)
  expect_error(
    install_library("zzz", method = "download"),
    "Not an installed package"
  )
})

test_that("method = 'download' takes no build options", {
  expect_error(
    install_library(method = "download", cpu_target = "generic"),
    "none of the build options: `cpu_target`"
  )
  expect_error(
    install_library(method = "download", julia = "julia", private = "a"),
    "`julia`, `private`"
  )
})

test_that("asking first can cancel a download", {
  local_download_env()
  local_offer(fake_archive())
  local_mocked_bindings(menu = function(choices, title) 2L, .package = "utils")
  expect_message(
    install_library("a", ask = TRUE, method = "download"),
    "Cancelled"
  )
  expect_false(dir.exists(installed_dir()))
})

test_that("builds keep pre-built private libraries", {
  local_download_env()
  local_offer(fake_archive())
  suppressMessages(install_library("a", ask = FALSE, method = "download"))
  local_mocked_bindings(jlbind_clients = function(...) fake_clients("a"))
  expect_message(
    install_library(ask = FALSE),
    "^Keeping the pre-built library of a; name it in `packages`[^\n]*\n$"
  )
  expect_true(.is_downloaded(.read_build(.private_dir("a"))))
})

test_that("a pre-built library is stale for another interface version only", {
  build <- list(
    jlbind = "0.0.1",
    Julia = "1.14.0",
    Bundle = "TRUE",
    Private = "jlabc",
    CpuTarget = "generic",
    ABI = as.character(.binary_abi),
    Download = "https://example.com/a.tar.gz",
    Develop = ""
  )
  expect_length(.build_reasons(build, NA), 0L)
  build$ABI <- "0"
  expect_match(.build_reasons(build, NA), "version 0 of jlbind's interface")
  build$Download <- NA
  expect_match(.build_reasons(build, NA), "built by jlbind 0.0.1", all = FALSE)
})

test_that("the hint for a stale pre-built library is to download it again", {
  lib <- new.env()
  lib$path <- "x/jlbind.so"
  lib$build <- list(Download = "https://example.com/a.tar.gz")
  expect_match(.rebuild_hint("a", lib), "method = \"download\"")
})

test_that("a malformed list of pre-built libraries is an error", {
  pkg <- withr::local_tempdir()
  dir.create(file.path(pkg, "jlbind"))
  writeLines(
    c("Version: 1.0", "OS: Linux", "Arch: x86_64", "URL: x", "SHA256: abc"),
    file.path(pkg, "jlbind", "binaries")
  )
  expect_error(
    .binaries("a", file.path(pkg, "jlbind", "binaries")),
    "malformed"
  )
  expect_equal(nrow(.binaries("a", "")), 0L)
})

test_that("the pre-built library for the installed version is preferred", {
  hash <- strrep("a", 64L)
  local_mocked_bindings(
    .binaries = function(pkg) {
      data.frame(
        Version = c("1.0", "1.1", "1.1"),
        OS = c("Linux", "Linux", "Darwin"),
        Arch = "x86_64",
        URL = c("u10", "u11", "mac"),
        SHA256 = hash
      )
    }
  )
  linux <- c(OS = "Linux", Arch = "x86_64")
  expect_equal(.binary_for("a", "1.1", linux)$URL, "u11")
  expect_equal(.binary_for("a", "2.0", linux)$URL, "u10")
  expect_equal(.binary_for("a", platform = linux)$URL, "u10")
  expect_null(.binary_for("a", "1.1", c(OS = "Windows", Arch = "x86_64")))
})
