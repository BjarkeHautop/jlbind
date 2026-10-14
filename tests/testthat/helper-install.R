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
  jlbind_path <- getNamespaceInfo("jlbind", "path")
  libpath <- c(lib, .Library)
  if (
    file.exists(file.path(jlbind_path, "DESCRIPTION")) &&
      !dir.exists(file.path(jlbind_path, "Meta"))
  ) {
    install(jlbind_path)
  } else {
    libpath <- c(lib, dirname(jlbind_path), .Library)
  }
  for (path in c(...)) {
    install(path)
  }
  libpath
}
