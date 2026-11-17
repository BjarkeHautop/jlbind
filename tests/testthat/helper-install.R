# Installs the packages in `paths` into a temporary library, along with the
# jlbind sources being tested when run under pkgload, and returns the library
# paths for a fresh R process to use.
local_install <- function(..., env = parent.frame()) {
  lib <- withr::local_tempdir(.local_envir = env)
  install <- function(path) {
    out <- system2(
      file.path(R.home("bin"), "R"),
      c("CMD", "INSTALL", "--no-test-load", "-l", shQuote(lib), shQuote(path)),
      stdout = TRUE,
      stderr = TRUE
    )
    if (!is.null(attr(out, "status"))) {
      stop("Installing ", path, " failed:\n", paste(out, collapse = "\n"))
    }
  }
  # Under pkgload, jlbind is not installed; install the sources being tested.
  jlbind_path <- find.package("jlbind")
  libpath <- c(lib, .Library)
  if (
    file.exists(file.path(jlbind_path, "DESCRIPTION")) &&
      !dir.exists(file.path(jlbind_path, "Meta"))
  ) {
    install(jlbind_path)
  } else {
    libpath <- c(lib, dirname(jlbind_path), .Library)
  }
  # covr's instrumented jlbind calls covr as it loads, so the process needs
  # covr and its dependencies, but not the other packages in their libraries.
  if (identical(Sys.getenv("R_COVR"), "true")) {
    covr_lib <- withr::local_tempdir(.local_envir = env)
    deps <- tools::package_dependencies(
      "covr",
      db = utils::installed.packages(),
      which = c("Depends", "Imports", "LinkingTo"),
      recursive = TRUE
    )[[1]]
    pkgs <- setdiff(
      c("covr", deps),
      rownames(utils::installed.packages(.Library))
    )
    file.symlink(find.package(pkgs), file.path(covr_lib, pkgs))
    libpath <- c(libpath, covr_lib)
  }
  for (path in c(...)) {
    install(path)
  }
  libpath
}
