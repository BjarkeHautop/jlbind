#' Build the Julia library
#'
#' Compiles the Julia code of every installed package that uses jlbind into one
#' shared library, stored in `tools::R_user_dir("jlbind", "data")`. Run this
#' after you install or update one of those packages. You need Julia 1.13 or
#' later. The first build downloads and compiles the Julia dependencies, which
#' can take a few minutes.
#'
#' All packages share one Julia environment. By default, the dependencies get
#' the versions in the first package's `Manifest.toml`. If two packages
#' conflict, the one listed later by [jlbind_clients()] is left out, and
#' [check_backend()] says why. See `vignette("jlbind")` for details.
#'
#' If a library is already loaded, restart R to use the new one. If the Julia
#' used for the build is updated or removed, rebuild with `force = TRUE`.
#'
#' @param packages Names of the installed packages to build. By default, every
#'   package listed by [jlbind_clients()]. The others aren't bound.
#' @param julia Path to the `julia` executable. By default, the `JULIA`
#'   environment variable, or `julia` on the `PATH`.
#' @param ask If `TRUE`, ask before building. Defaults to [interactive()].
#' @param force If `TRUE`, rebuild even if the library is up to date. Always on
#'   with `update` or `develop`.
#' @param update If `TRUE`, use the newest dependency versions instead of those
#'   in the packages' `Manifest.toml` files.
#' @param develop Paths to local Julia packages to use instead of their released
#'   versions.
#'
#' @return The path to the library (invisibly), or `NULL` if there was nothing
#'   to build.
#' @export
#' @examples
#' \dontrun{
#' install_backend()
#'
#' # With a local checkout of a Julia dependency
#' install_backend(develop = "~/dev/SomePackage.jl")
#'
#' # Only two of the installed packages
#' install_backend(packages = c("pkgA", "pkgB"))
#' }
install_backend <- function(
  packages = NULL,
  julia = NULL,
  ask = interactive(),
  force = FALSE,
  update = FALSE,
  develop = NULL
) {
  clients <- jlbind_clients()
  if (!is.null(packages)) {
    missing <- setdiff(packages, clients$package)
    if (length(missing)) {
      stop(
        "Not an installed package that uses jlbind: ",
        paste(missing, collapse = ", "),
        ".",
        call. = FALSE
      )
    }
    clients <- clients[clients$package %in% packages, , drop = FALSE]
  }
  if (nrow(clients) == 0L) {
    message("No installed package uses jlbind, so there is nothing to build.")
    return(invisible(NULL))
  }
  dir <- .backend_dir()
  path <- file.path(dir, .library_file())
  if (!force && !update && !length(develop) && .up_to_date(dir, clients)) {
    message(
      "The compiled Julia library is up to date (",
      path,
      "); use `force = TRUE` to rebuild it."
    )
    .bind_requested()
    return(invisible(path))
  }

  julia <- .find_julia(julia)
  if (isTRUE(ask)) {
    choice <- utils::menu(
      c("Yes", "No"),
      title = paste0(
        "Compile the Julia code of ",
        paste(clients$package, collapse = ", "),
        " with ",
        julia,
        "? Julia downloads their Julia dependencies into its package depot, ",
        "and compiling takes several minutes. The library is written to ",
        dir,
        "."
      )
    )
    if (choice != 1L) {
      message("Cancelled.")
      return(invisible(NULL))
    }
  }

  # Built next to its final place, so it is moved in with a rename, and only
  # once the build has succeeded.
  root <- dirname(dir)
  dir.create(root, recursive = TRUE, showWarnings = FALSE)
  out <- tempfile("build-", tmpdir = root)
  on.exit(unlink(out, recursive = TRUE), add = TRUE)
  .build(clients, out, julia, update, develop)

  # A loaded library cannot be deleted on Windows, but it can be renamed, so
  # the old build is moved aside first; whatever cannot be removed now is
  # pruned on the next build.
  if (dir.exists(dir)) {
    old <- tempfile("old-", tmpdir = root)
    if (!file.rename(dir, old)) {
      stop("Could not replace the library in ", dir, ".", call. = FALSE)
    }
  }
  if (!file.rename(out, dir)) {
    stop("Could not move the library into ", dir, ".", call. = FALSE)
  }
  for (stale in setdiff(list.files(root), basename(dir))) {
    unlink(file.path(root, stale), recursive = TRUE)
  }

  if (!is.null(.state$dll)) {
    message(
      "Built the compiled Julia library. Restart R to use it in place of ",
      "the library loaded in this session."
    )
  } else {
    message("Built the compiled Julia library.")
    .bind_requested()
  }
  invisible(path)
}

#' Build a Julia library from specific packages
#'
#' Like [install_backend()], but compiles only `packages` and writes the library
#' to `out`, for package development. By default, it builds the package in the
#' working directory into its `.jlbind/` directory, which `devtools::load_all()`
#' then uses instead of the library from [install_backend()]. To use a library
#' written elsewhere, set `JLBIND_LIBRARY` to its path before loading the
#' package.
#'
#' @param packages Names of installed packages, or paths to package sources or
#'   installed packages.
#' @param out Directory to write the library to. Defaults to `.jlbind/` in the
#'   sources of `packages`, which must then be a single source directory.
#' @inheritParams install_backend
#'
#' @return The path to the library, invisibly.
#' @export
#' @examples
#' \dontrun{
#' # In the sources of a package that uses jlbind
#' build_library()
#' devtools::load_all()
#'
#' # Several packages, used through JLBIND_LIBRARY
#' lib <- build_library(c("pkg1", "pkg2"), "jlbind-lib")
#' Sys.setenv(JLBIND_LIBRARY = lib)
#' }
build_library <- function(
  packages = ".",
  out = NULL,
  julia = NULL,
  update = FALSE,
  develop = NULL
) {
  if (is.null(out)) {
    if (length(packages) != 1L || !dir.exists(packages)) {
      stop(
        "`out` is needed unless `packages` is a single source directory.",
        call. = FALSE
      )
    }
    out <- file.path(packages, .dev_dir)
  }
  infos <- lapply(packages, function(p) {
    if (dir.exists(p)) .client_info(p) else .client_info(find.package(p))
  })
  clients <- .client_table(infos)
  julia <- .find_julia(julia)
  .build(clients, out, julia, update, develop)
  invisible(file.path(normalizePath(out), .library_file()))
}

# Compiles `clients` (a .client_table()) into `out`, with the metadata the
# runtime checks clients against.
.build <- function(clients, out, julia, update, develop = NULL) {
  if (anyDuplicated(clients$module)) {
    dup <- clients$module[duplicated(clients$module)][[1L]]
    stop(
      "Two packages (",
      paste(clients$package[clients$module == dup], collapse = ", "),
      ") have a Julia binding package named ",
      dup,
      "; each needs its own name.",
      call. = FALSE
    )
  }
  if (length(develop)) {
    develop <- normalizePath(develop, mustWork = TRUE)
  }
  trim <- all(clients$trim)
  if (!trim) {
    message(
      "Building without --trim, because ",
      paste(clients$package[!clients$trim], collapse = ", "),
      " set `",
      .trim_field,
      ": false`. The library is larger and may compile code when it runs."
    )
  }
  dir.create(out, recursive = TRUE, showWarnings = FALSE)
  script <- system.file("julia", "build.jl", package = "jlbind")
  status <- .run_julia(
    julia,
    c(
      shQuote(script),
      shQuote(out),
      if (isTRUE(update)) "--update",
      if (!trim) "--no-trim",
      if (length(develop)) {
        shQuote(paste0("--develop=", develop))
      },
      shQuote(clients$path)
    )
  )
  if (!identical(status, 0L) || !file.exists(file.path(out, .library_file()))) {
    stop(
      "Compiling the Julia library failed; see the output above.",
      call. = FALSE
    )
  }
  # Clients whose dependencies conflict with others' are left out (see
  # build.jl), and recorded with the clients they conflict with.
  conflicts <- .read_conflicts(file.path(out, "conflicts"), clients)
  unlink(file.path(out, "conflicts"))
  left_out <- clients$package %in% names(conflicts)
  meta <- data.frame(
    Package = clients$package,
    Version = clients$version,
    Module = clients$module
  )
  write.dcf(meta[!left_out, , drop = FALSE], file.path(out, "clients"))
  excluded <- meta[left_out, c("Package", "Version"), drop = FALSE]
  excluded$Conflicts <- vapply(
    conflicts[excluded$Package],
    paste,
    "",
    collapse = ", "
  )
  write.dcf(excluded, file.path(out, "excluded"))
  for (pkg in excluded$Package) {
    message(.excluded_message(pkg, conflicts[[pkg]], clients$package))
  }
  write.dcf(
    data.frame(
      jlbind = as.character(utils::packageVersion("jlbind")),
      Julia = as.character(.julia_version(julia)),
      Built = format(Sys.time(), tz = "UTC", usetz = TRUE),
      Trim = trim,
      # Built with local checkouts: not what a plain install_backend() builds.
      Develop = paste(develop, collapse = "\n")
    ),
    file.path(out, "build")
  )
  invisible(out)
}

# The clients build.jl left out, as a list from package name to the names of
# the packages it conflicts with. build.jl writes one line per binding
# package: its name, a tab and the comma-separated names it conflicts with.
.read_conflicts <- function(file, clients) {
  lines <- if (file.exists(file)) readLines(file, warn = FALSE) else character()
  lines <- lines[nzchar(lines)]
  pkg <- function(module) clients$package[match(module, clients$module)]
  parts <- strsplit(lines, "\t", fixed = TRUE)
  out <- lapply(parts, function(p) {
    with <- if (length(p) > 1L) strsplit(p[[2L]], ",", fixed = TRUE)[[1L]]
    pkg(with)
  })
  names(out) <- pkg(vapply(parts, `[[`, "", 1L))
  out
}

# Why `pkg` was left out of the library, conflicting with `with`, out of the
# packages `all`.
.excluded_message <- function(pkg, with, all) {
  if (!length(with)) {
    return(paste0(
      pkg,
      " was left out of the compiled Julia library: its Julia dependencies ",
      "cannot be resolved. See the output of jlbind::install_backend()."
    ))
  }
  keep <- c(pkg, setdiff(all, c(pkg, with)))
  paste0(
    pkg,
    " was left out of the compiled Julia library: its Julia dependencies ",
    "conflict with those of ",
    paste(with, collapse = ", "),
    ". To use ",
    pkg,
    " instead, run jlbind::install_backend(packages = ",
    .deparse_chr(keep),
    ") and restart R."
  )
}

.deparse_chr <- function(x) {
  x <- paste0('"', x, '"')
  if (length(x) == 1L) x else paste0("c(", paste(x, collapse = ", "), ")")
}

# Where install_backend() builds the library.
.backend_dir <- function() {
  file.path(tools::R_user_dir("jlbind", "data"), "backend")
}

.library_file <- function() {
  ext <- switch(
    Sys.info()[["sysname"]],
    Darwin = ".dylib",
    Windows = ".dll",
    ".so"
  )
  paste0("jlbind", ext)
}

# The clients a library in `dir` was built from (a data frame with Package,
# Version, Module), or NULL if it records none.
.read_clients <- function(dir) {
  file <- file.path(dir, "clients")
  if (!file.exists(file)) {
    return(NULL)
  }
  as.data.frame(read.dcf(file), stringsAsFactors = FALSE)
}

# The clients left out of the library in `dir` (a data frame with Package,
# Version, Conflicts), or NULL if it records none.
.read_excluded <- function(dir) {
  file <- file.path(dir, "excluded")
  if (!file.exists(file) || !length(readLines(file, warn = FALSE))) {
    return(NULL)
  }
  as.data.frame(read.dcf(file), stringsAsFactors = FALSE)
}

# Was the library in `dir` built by this version of jlbind from exactly these
# versions of these clients (counting those it left out), and with no local
# checkouts?
.up_to_date <- function(dir, clients) {
  built <- .read_clients(dir)
  build <- file.path(dir, "build")
  if (
    is.null(built) ||
      !file.exists(file.path(dir, .library_file())) ||
      !file.exists(build)
  ) {
    return(FALSE)
  }
  info <- read.dcf(build, fields = c("jlbind", "Develop"))
  identical(
    info[, "jlbind"][[1L]],
    as.character(utils::packageVersion("jlbind"))
  ) &&
    (is.na(info[, "Develop"]) || !nzchar(info[, "Develop"])) &&
    setequal(
      paste(
        c(built$Package, .read_excluded(dir)$Package),
        c(built$Version, .read_excluded(dir)$Version)
      ),
      paste(clients$package, clients$version)
    )
}
