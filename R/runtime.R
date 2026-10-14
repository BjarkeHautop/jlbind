# The process holds one Julia runtime, running one compiled library, so the
# library is loaded once, the first time a client binds, and every client binds
# its routines to it.
#
# .state$dll        the loaded library's DLLInfo, NULL until loaded
# .state$path       where the library was looked for
# .state$clients    the clients the library was built from (.read_clients())
# .state$excluded   the clients it left out (.read_excluded())
# .state$problem    why the library could not be loaded, if it was not
# .state$requested  the clients that asked to be bound
# .state$bound      the clients that are bound
# .state$problems   why each client that asked could not be bound, by name
.state <- new.env(parent = emptyenv())
.state$requested <- character()
.state$bound <- character()
.state$problems <- list()

# The library to load: JLBIND_LIBRARY, else one built into the sources of
# `pkg` (.dev_library()), else the one install_library() builds.
.library_path <- function(pkg = NULL) {
  override <- Sys.getenv("JLBIND_LIBRARY", unset = "")
  if (nzchar(override)) {
    return(override)
  }
  dev <- if (!is.null(pkg)) .dev_library(pkg)
  if (!is.null(dev)) {
    return(dev)
  }
  file.path(.library_dir(), .library_file())
}

# Where build_library() writes by default in a package's sources. It is at the
# top level, so it is never installed with the package.
.dev_dir <- ".jlbind"

# The library build_library() wrote into the sources of `pkg`, or NULL. A
# namespace's path is the source directory when it was loaded with
# pkgload::load_all(), and an installed package has no .dev_dir.
.dev_library <- function(pkg) {
  path <- file.path(
    getNamespaceInfo(pkg, "path"),
    .dev_dir,
    .library_file()
  )
  if (file.exists(path)) path
}

# Loads the library unless it is already loaded; TRUE if it is. `pkg` is the
# client asking for it.
.load_library <- function(pkg = NULL) {
  if (!is.null(.state$dll)) {
    return(TRUE)
  }
  path <- .library_path(pkg)
  .state$path <- path
  if (!file.exists(path)) {
    .state$problem <- paste0(
      "The compiled Julia library has not been built (it was looked for at ",
      path,
      "). Run jlbind::install_library() to build it; this needs Julia >= 1.13."
    )
    return(FALSE)
  }
  # The library links against the Julia that built it, so it stops loading
  # if that Julia is removed (e.g. by a juliaup update).
  .add_julia_bindir(path)
  dll <- tryCatch(dyn.load(path, local = TRUE, now = TRUE), error = identity)
  if (inherits(dll, "error")) {
    .state$problem <- paste0(
      "The compiled Julia library (",
      path,
      ") could not be loaded; the Julia it was built with may have been ",
      "removed or updated. Run jlbind::install_library(force = TRUE) in a ",
      "new R session to rebuild it.\n",
      conditionMessage(dll)
    )
    return(FALSE)
  }
  .set_threads(dll)
  .state$dll <- dll
  .state$clients <- .read_clients(dirname(path))
  .state$excluded <- .read_excluded(dirname(path))
  .state$problem <- NULL
  TRUE
}

# Sets the Julia thread count from JULIA_NUM_THREADS. Must run before the
# first entrypoint call, which initializes Julia.
.set_threads <- function(dll) {
  threads <- .julia_threads()
  if (threads == 1L) {
    return(invisible(NULL))
  }
  f <- getNativeSymbolInfo("jlbind_set_julia_threads", dll)
  status <- .C(f, threads = threads, status = 0L)$status
  if (status != 0L) {
    warning(
      "Could not set ",
      threads,
      " Julia threads; using one.",
      call. = FALSE
    )
  }
  invisible(NULL)
}

# The Julia thread count from JULIA_NUM_THREADS: a count or "auto". A juliac
# library ignores the variable itself. Anything after a comma (the interactive
# threadpool) is ignored.
.julia_threads <- function() {
  value <- sub(",.*", "", Sys.getenv("JULIA_NUM_THREADS", unset = ""))
  if (!nzchar(value)) {
    return(1L)
  }
  n <- if (value == "auto") {
    parallel::detectCores()
  } else {
    suppressWarnings(as.integer(value))
  }
  if (is.na(n) || n < 1L) {
    warning(
      "Ignoring JULIA_NUM_THREADS = \"",
      value,
      "\"; using one Julia thread.",
      call. = FALSE
    )
    return(1L)
  }
  as.integer(n)
}

# On Windows the library has no RUNPATH, so the directory of the Julia
# runtime it links against (recorded by build.jl next to it) is put on the
# PATH, where Windows finds libjulia.dll and its dependencies.
.add_julia_bindir <- function(path, windows = .Platform$OS.type == "windows") {
  if (!windows) {
    return(invisible(NULL))
  }
  record <- file.path(dirname(path), "julia_bindir")
  if (!file.exists(record)) {
    return(invisible(NULL))
  }
  bindir <- normalizePath(
    readLines(record, warn = FALSE)[[1L]],
    mustWork = FALSE
  )
  dirs <- strsplit(Sys.getenv("PATH"), ";", fixed = TRUE)[[1L]]
  if (!tolower(bindir) %in% tolower(normalizePath(dirs, mustWork = FALSE))) {
    Sys.setenv(PATH = paste(c(bindir, dirs), collapse = ";"))
  }
  invisible(NULL)
}

#' Bind a package to the Julia library
#'
#' Call this from the `.onLoad()` of a package that uses jlbind; [use_jlbind()]
#' sets that up. The first call loads the compiled library, and each call binds
#' one package's routines to it. If the library is missing or was built from
#' another version of the package, the package isn't bound and its functions
#' give an error; [check_bound()] says why.
#'
#' The library is the one from [install_library()], unless `JLBIND_LIBRARY`
#' names another, or the first package bound was loaded with
#' `pkgload::load_all()` and has one from [build_library()].
#'
#' To run Julia with more threads, set `JULIA_NUM_THREADS` (a number or
#' `"auto"`) before loading the first package that uses jlbind.
#'
#' @param pkg The package name.
#'
#' @return Invisibly, `TRUE` if the package is bound and `FALSE` if not.
#' @export
#' @examples
#' \dontrun{
#' # In a package's R/jlbind.R, as use_jlbind() writes it
#' .onLoad <- function(libname, pkgname) {
#'   jlbind::bind_client(pkgname)
#' }
#' }
bind_client <- function(pkg) {
  .state$requested <- union(.state$requested, pkg)
  if (pkg %in% .state$bound) {
    return(invisible(TRUE))
  }
  if (!.load_library(pkg)) {
    return(invisible(FALSE))
  }
  problem <- .bind_problem(pkg)
  if (is.null(problem)) {
    # The package's routines can only be looked up by registration, as the
    # package forces symbols.
    info <- getDLLRegisteredRoutines(pkg)$.Call$jlbind_bind
    res <- if (is.null(info)) {
      simpleError(paste0(
        "Package ",
        pkg,
        " has no routine `jlbind_bind`; its src/jlbind.c is missing or out ",
        "of date (run jlbind::use_jlbind() on its sources)."
      ))
    } else {
      tryCatch(.Call(info, .state$dll[["name"]]), error = identity)
    }
    if (inherits(res, "error")) {
      problem <- conditionMessage(res)
    }
  }
  .state$problems[[pkg]] <- problem
  if (!is.null(problem)) {
    return(invisible(FALSE))
  }
  .state$bound <- union(.state$bound, pkg)
  invisible(TRUE)
}

# Why the loaded library cannot serve `pkg`, or NULL if it can. A library
# that records no clients (one built some other way) is trusted.
.bind_problem <- function(pkg) {
  built <- .state$clients
  if (is.null(built)) {
    return(NULL)
  }
  version <- as.character(getNamespaceVersion(pkg))
  row <- built[built$Package == pkg, , drop = FALSE]
  excluded <- .state$excluded
  if (nrow(row) == 0L && pkg %in% excluded$Package) {
    with <- excluded$Conflicts[excluded$Package == pkg]
    with <- if (nzchar(with)) strsplit(with, ", ", fixed = TRUE)[[1L]]
    return(.excluded_message(
      pkg,
      with,
      c(built$Package, excluded$Package)
    ))
  }
  if (nrow(row) == 0L) {
    return(paste0(
      "The compiled Julia library was built without ",
      pkg,
      ". Run jlbind::install_library() to rebuild it, then restart R."
    ))
  }
  if (!identical(row$Version[[1L]], version)) {
    return(paste0(
      "The compiled Julia library was built for ",
      pkg,
      " ",
      row$Version[[1L]],
      ", not the installed version ",
      version,
      ". Run jlbind::install_library() to rebuild it, then restart R."
    ))
  }
  NULL
}

# Binds the clients that asked to be, once a library has been built.
.bind_requested <- function() {
  for (pkg in setdiff(.state$requested, .state$bound)) {
    if (isNamespaceLoaded(pkg)) {
      bind_client(pkg)
    }
  }
  invisible(NULL)
}

#' Check whether a package is bound to the Julia library
#'
#' `is_bound()` returns `TRUE` or `FALSE`. `check_bound()` gives an error that
#' explains why the package isn't bound.
#'
#' @param pkg Name of a package that uses jlbind.
#'
#' @return `is_bound()`: `TRUE` or `FALSE`. `check_bound()`: `TRUE`
#'   (invisibly) if the package is bound, otherwise an error.
#' @export
#' @examples
#' # Not bound, as no package named mypkg has been loaded
#' is_bound("mypkg")
#' try(check_bound("mypkg"))
is_bound <- function(pkg) {
  pkg %in% .state$bound
}

#' @rdname is_bound
#' @export
check_bound <- function(pkg) {
  if (is_bound(pkg)) {
    return(invisible(TRUE))
  }
  if (!pkg %in% .state$requested) {
    stop(
      "Package ",
      pkg,
      " has not asked to be bound; is it loaded, and does it call ",
      "jlbind::bind_client() from its .onLoad()?",
      call. = FALSE
    )
  }
  stop(
    if (is.null(.state$dll)) .state$problem else .state$problems[[pkg]],
    call. = FALSE
  )
}

#' Information about the loaded Julia library
#'
#' @return A list with:
#'   * `path`: where the library is, or `NULL` if none is loaded.
#'   * `clients`: a data frame with one row per package the library was built
#'     for, with the columns `package`, `version` and `module` (the name of its
#'     Julia binding package), as in [jlbind_clients()], and:
#'     * `included`: `FALSE` if it was left out because its Julia dependencies
#'       conflict with those of other packages (see [install_library()]).
#'     * `bound`: whether it is bound to the library in this session.
#'   * `objects`: how many Julia objects R holds references to, or `NULL` if no
#'     library is loaded.
#' @export
#' @examples
#' library_info()
library_info <- function() {
  dll <- .state$dll
  objects <- NULL
  if (!is.null(dll)) {
    count <- getNativeSymbolInfo("JLBind_object_count", dll)
    objects <- .Call(count)
  }
  list(
    path = if (!is.null(dll)) .state$path,
    clients = .info_clients(.state$clients, .state$excluded, .state$bound),
    objects = objects
  )
}

# The clients table of library_info(), from the clients a library was built
# from and left out (.read_clients(), .read_excluded()) and those bound. A
# library that records no clients (one built some other way) still lists the
# clients bound to it.
.info_clients <- function(built, excluded, bound) {
  col <- function(df, name) {
    if (is.null(df[[name]])) rep(NA_character_, NROW(df)) else df[[name]]
  }
  package <- c(col(built, "Package"), col(excluded, "Package"))
  extra <- setdiff(bound, package)
  unknown <- rep(NA_character_, length(extra))
  data.frame(
    package = c(package, extra),
    version = c(col(built, "Version"), col(excluded, "Version"), unknown),
    module = c(col(built, "Module"), col(excluded, "Module"), unknown),
    included = c(
      rep(TRUE, NROW(built)),
      rep(FALSE, NROW(excluded)),
      rep(TRUE, length(extra))
    ),
    bound = c(package, extra) %in% bound,
    stringsAsFactors = FALSE
  )
}
