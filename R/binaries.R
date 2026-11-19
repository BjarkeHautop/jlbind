# The package author's side of pre-built libraries (download.R has the user's
# side): build_binary() builds, checks and archives the library of a package
# for this platform, as the workflow use_jlbind_binaries() writes does on each
# OS, and record_binaries() lists the archives of a GitHub release in the
# package's inst/jlbind/binaries.

#' Build a pre-built library for a package
#'
#' Builds a private library ([build_library()] with `private = TRUE`) for any
#' CPU from the package at `path` (on x86-64, with code for newer CPUs as well,
#' as in Julia's own builds), prunes it with `prune`, runs the package's
#' tests against it without Julia, and archives it as
#' `<out>/<package>_<version>_<OS>-<arch>.tar.gz`, for
#' `install_library(method = "download")`. On Windows, `JLBIND_JULIAC` must name
#' a JuliaC that can give a library a private runtime there, such as that of
#' [JuliaC.jl#151](https://github.com/JuliaLang/JuliaC.jl/pull/151).
#'
#' @param path Path to the package sources.
#' @param out Directory to write the archive to.
#' @param prune `NULL`, a function that removes files from the library's
#'   directory, or the path to an R script whose value is one.
#' @param check If `TRUE`, run the package's tests against the library first.
#' @inheritParams install_library
#'
#' @return The path to the archive, invisibly.
#' @export
#' @examples
#' \dontrun{
#' # In the sources of a package that uses jlbind
#' build_binary(prune = "tools/prune-binary.R")
#' }
build_binary <- function(
  path = ".",
  out = "binary",
  prune = NULL,
  check = TRUE,
  julia = NULL
) {
  desc <- read.dcf(file.path(path, "DESCRIPTION"), c("Package", "Version"))
  pkg <- desc[[1L, "Package"]]
  version <- desc[[1L, "Version"]]
  platform <- .platform()
  windows <- platform[["OS"]] == "Windows"
  if (windows && !nzchar(.juliac())) {
    stop(
      "A pre-built library needs a private Julia runtime, which released ",
      "JuliaC can't give a library on Windows yet. Set JLBIND_JULIAC to a ",
      "JuliaC that can, such as \"",
      .juliac_windows,
      "\".",
      call. = FALSE
    )
  }
  if (is.character(prune)) {
    prune <- source(prune, local = new.env())$value
  }
  if (!is.null(prune) && !is.function(prune)) {
    stop(
      "`prune` must be a function, or an R script whose value is one.",
      call. = FALSE
    )
  }
  name <- paste0(
    pkg,
    "_",
    version,
    "_",
    platform[["OS"]],
    "-",
    platform[["Arch"]]
  )
  work <- tempfile("binary-")
  on.exit(unlink(work, recursive = TRUE), add = TRUE)
  dir <- file.path(work, name)
  lib <- build_library(
    path,
    dir,
    julia = julia,
    cpu_target = .binary_cpu_target(platform[["Arch"]]),
    private = TRUE
  )
  message("Built ", lib, " (", .dir_size(dir), ").")
  if (!is.null(prune)) {
    prune(dir)
    if (!file.exists(lib)) {
      stop("`prune` removed the library itself.", call. = FALSE)
    }
    message("Pruned the library's runtime: ", .dir_size(dir), ".")
  }
  if (!windows && nzchar(Sys.which("strip"))) {
    status <- system2(
      "strip",
      c(
        if (platform[["OS"]] == "Darwin") "-x" else "--strip-unneeded",
        shQuote(lib)
      )
    )
    if (!identical(status, 0L)) {
      stop("Could not strip ", lib, ".", call. = FALSE)
    }
    # Stripping invalidates the ad-hoc code signature that macOS on Apple
    # silicon needs to load a library, so it is signed again.
    if (platform[["OS"]] == "Darwin") {
      status <- system2("codesign", c("--force", "--sign", "-", shQuote(lib)))
      if (!identical(status, 0L)) {
        stop("Could not sign ", lib, ".", call. = FALSE)
      }
    }
  }
  if (check) {
    .check_binary(path, pkg, lib)
  }
  dir.create(out, recursive = TRUE, showWarnings = FALSE)
  archive <- file.path(normalizePath(out), paste0(name, ".tar.gz"))
  status <- system2("tar", c("-czf", shQuote(archive), "-C", shQuote(dir), "."))
  if (!identical(status, 0L)) {
    stop("Could not write ", archive, ".", call. = FALSE)
  }
  message(
    "Wrote ",
    archive,
    sprintf(" (%.1f MB), with SHA-256 hash ", file.size(archive) / 1e6),
    .sha256(archive),
    "."
  )
  invisible(archive)
}

# The CPU target of pre-built libraries for the architecture `arch`: on
# x86-64, Julia's own, which adds code for the CPUs of the last decade to the
# generic code; elsewhere, generic code.
.binary_cpu_target <- function(arch) {
  if (arch %in% c("x86_64", "x86-64", "amd64")) {
    "generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1)"
  } else {
    "generic"
  }
}

# The size of the files in `dir`, counting symbolic links as nothing.
.dir_size <- function(dir) {
  files <- list.files(dir, recursive = TRUE, full.names = TRUE)
  files <- files[!nzchar(Sys.readlink(files))]
  sprintf("%.1f MB", sum(file.size(files), na.rm = TRUE) / 1e6)
}

# Runs the tests of the package `pkg` in `path` against the library `lib` in a
# new R process, with Julia's directories off the PATH and the library search
# paths, so that a runtime library removed from the bundle can't be found
# there instead.
.check_binary <- function(path, pkg, lib) {
  for (p in c("pkgload", "testthat")) {
    if (!requireNamespace(p, quietly = TRUE)) {
      stop("Checking the library needs the ", p, " package.", call. = FALSE)
    }
  }
  sep <- .Platform$path.sep
  search <- c("PATH", "LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH")
  # system2() ignores `env` on Windows, so the variables are set here for the
  # child process.
  vars <- c(search, "JLBIND_LIBRARY", "NOT_CRAN")
  old <- Sys.getenv(vars, unset = NA)
  on.exit({
    do.call(Sys.setenv, as.list(old[!is.na(old)]))
    Sys.unsetenv(vars[is.na(old)])
  })
  without_julia <- function(var) {
    dirs <- strsplit(Sys.getenv(var), sep, fixed = TRUE)[[1L]]
    paste(dirs[!grepl("julia", dirs, ignore.case = TRUE)], collapse = sep)
  }
  do.call(Sys.setenv, as.list(vapply(search, without_julia, "")))
  Sys.setenv(JLBIND_LIBRARY = lib, NOT_CRAN = "true")
  script <- tempfile(fileext = ".R")
  on.exit(unlink(script), add = TRUE)
  writeLines(
    c(
      paste0("path <- ", deparse(normalizePath(path))),
      "pkgload::load_all(path, quiet = TRUE)",
      paste0("jlbind::check_bound(", deparse(pkg), ")"),
      "testthat::test_dir(",
      "  file.path(path, 'tests', 'testthat'),",
      "  load_package = 'none',",
      "  stop_on_failure = TRUE",
      ")"
    ),
    script
  )
  status <- system2(file.path(R.home("bin"), "Rscript"), shQuote(script))
  if (!identical(status, 0L)) {
    stop(
      "The tests failed with the pre-built library. If a library could not ",
      "be loaded from its jlbind-bundle, `prune` removed one it needs.",
      call. = FALSE
    )
  }
  invisible(NULL)
}

#' List the pre-built libraries of a release in a package
#'
#' Downloads the pre-built libraries of a GitHub release with the
#' [GitHub CLI](https://cli.github.com/), checks them, and writes their
#' version, platform, URL and SHA-256 hash to `inst/jlbind/binaries`, which
#' `install_library(method = "download")` reads. Commit the file and release
#' that commit.
#'
#' @param path Path to the package sources.
#' @param repo The GitHub repository, as `"owner/name"`. By default, the first
#'   GitHub URL in the package's `URL` field.
#' @param tag The release's tag. By default, `v` and the package's version.
#'
#' @return The path to `inst/jlbind/binaries`, invisibly.
#' @export
#' @examples
#' \dontrun{
#' # In the sources of a package that uses jlbind, once its release has its
#' # pre-built libraries
#' record_binaries()
#' }
record_binaries <- function(path = ".", repo = NULL, tag = NULL) {
  desc <- read.dcf(
    file.path(path, "DESCRIPTION"),
    c("Package", "Version", "URL")
  )
  pkg <- desc[[1L, "Package"]]
  version <- desc[[1L, "Version"]]
  if (is.null(tag)) {
    tag <- paste0("v", version)
  }
  if (is.null(repo)) {
    urls <- trimws(strsplit(desc[[1L, "URL"]], "[,[:space:]]+")[[1L]])
    urls <- grep("^https://github\\.com/[^/]+/[^/]+", urls, value = TRUE)
    if (!length(urls)) {
      stop(
        "The package's URL field names no GitHub repository; pass `repo`.",
        call. = FALSE
      )
    }
    repo <- sub("^https://github\\.com/([^/]+/[^/#?]+).*$", "\\1", urls[[1L]])
    repo <- sub("\\.git$", "", repo)
  }
  dir <- tempfile("binaries-")
  dir.create(dir)
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)
  prefix <- paste0(pkg, "_", version, "_")
  status <- .gh_download(repo, tag, paste0(prefix, "*.tar.gz"), dir)
  archives <- list.files(dir, "\\.tar\\.gz$", full.names = TRUE)
  if (!identical(status, 0L) || !length(archives)) {
    stop(
      "Could not download pre-built libraries of ",
      pkg,
      " ",
      version,
      " from release ",
      tag,
      " of ",
      repo,
      ".",
      call. = FALSE
    )
  }
  records <- lapply(archives, function(archive) {
    name <- basename(archive)
    platform <- sub("\\.tar\\.gz$", "", substring(name, nchar(prefix) + 1L))
    unpacked <- tempfile("unpacked-", tmpdir = dir)
    utils::untar(archive, exdir = unpacked)
    problem <- .binary_problem(unpacked, pkg, version)
    if (!is.null(problem)) {
      stop(name, " can't be used: ", problem, ".", call. = FALSE)
    }
    data.frame(
      Version = version,
      OS = sub("-.*", "", platform),
      Arch = sub("^[^-]*-", "", platform),
      URL = paste0(
        "https://github.com/",
        repo,
        "/releases/download/",
        tag,
        "/",
        name
      ),
      SHA256 = .sha256(archive)
    )
  })
  file <- file.path(path, "inst", "jlbind", "binaries")
  dir.create(dirname(file), recursive = TRUE, showWarnings = FALSE)
  write.dcf(do.call(rbind, records), file)
  message(
    "Wrote ",
    file,
    " with the pre-built libraries for ",
    paste(
      vapply(records, function(r) paste0(r$OS, " (", r$Arch, ")"), ""),
      collapse = ", "
    ),
    "."
  )
  invisible(file)
}

# Downloads the assets of release `tag` of the GitHub repository `repo` that
# match `pattern` into `dir` with the GitHub CLI; its exit status.
.gh_download <- function(repo, tag, pattern, dir) {
  if (!nzchar(Sys.which("gh"))) {
    stop("Downloading the release needs the GitHub CLI, `gh`.", call. = FALSE)
  }
  system2(
    "gh",
    c(
      "release",
      "download",
      shQuote(tag),
      "--repo",
      shQuote(repo),
      "--pattern",
      shQuote(pattern),
      "--dir",
      shQuote(dir)
    )
  )
}
