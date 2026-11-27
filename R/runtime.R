# The process holds one shared Julia runtime, running one compiled library,
# so that library is loaded once, the first time a client binds to it, and
# every client binds its routines to it. A client can instead have a library
# of its own with a private copy of the Julia runtime (install_library(private
# = ), build_library(private = TRUE)), which loads alongside the shared one.
#
# The state of a library is an environment: `.state` itself for the shared
# library, and one in `.state$private`, by path, for each private library.
#
# $dll        the loaded library's DLLInfo, NULL until loaded
# $path       where the library was looked for
# $clients    the clients the library was built from (.read_clients())
# $excluded   the clients it left out (.read_excluded())
# $build      how it was built (.read_build())
# $problem    why the library could not be loaded, if it was not
#
# and in `.state` alone:
#
# .state$requested  the clients that asked to be bound
# .state$bound      the clients that are bound
# .state$problems   why each client that asked could not be bound, by name
# .state$libraries  the state of the library each client asked for, by name
.state <- new.env(parent = emptyenv())
.state$requested <- character()
.state$bound <- character()
.state$problems <- list()
.state$private <- list()
.state$libraries <- list()

# The library to load: JLBIND_LIBRARY, else one built into the sources of
# `pkg` (.dev_library()), else the private library install_library() built
# for `pkg`, else the shared one it builds.
.library_path <- function(pkg = NULL) {
  override <- Sys.getenv("JLBIND_LIBRARY", unset = "")
  if (nzchar(override)) {
    return(override)
  }
  dev <- if (!is.null(pkg)) .dev_library(pkg)
  if (!is.null(dev)) {
    return(dev)
  }
  private <- if (!is.null(pkg)) .private_library(pkg)
  if (!is.null(private)) {
    return(private)
  }
  file.path(.library_dir(), .library_file())
}

# The private library install_library() builds for `pkg`, if it recorded `pkg`
# as private, or NULL. It may be missing, as when the cache was cleared; then
# loading it says to run install_library().
.private_library <- function(pkg) {
  if (pkg %in% .read_private()) file.path(.private_dir(pkg), .library_file())
}

# Whether the library at `path` has a private Julia runtime, as recorded when
# it was built. One install_library() builds privately counts as private before
# it exists, so that it gets its own state.
.is_private <- function(path) {
  if (.is_installed_private(path)) {
    return(TRUE)
  }
  private <- .read_build(dirname(path))$Private
  !is.null(private) && nzchar(private)
}

# The state of the library at `path`: its own for a private library, else the
# shared library's (which may be another library already loaded).
.library_state <- function(path) {
  if (!.is_private(path)) {
    return(.state)
  }
  key <- normalizePath(path, mustWork = FALSE)
  lib <- .state$private[[key]]
  if (is.null(lib)) {
    lib <- new.env(parent = emptyenv())
    .state$private[[key]] <- lib
  }
  lib
}

# The states of the libraries that are loaded.
.loaded_libraries <- function() {
  libs <- c(list(.state), unname(.state$private))
  Filter(function(lib) !is.null(lib$dll), libs)
}

# Where build_library() writes by default in a package's sources. It is at the
# top level, so it is never installed with the package.
.dev_dir <- ".jlbind"

# The library build_library() wrote into the sources of `pkg`, or NULL. For a
# loaded package, find.package() gives the directory it was loaded from: the
# sources when it was loaded with pkgload::load_all(), and an installed
# package has no .dev_dir.
.dev_library <- function(pkg) {
  dir <- find.package(pkg, quiet = TRUE)
  if (!length(dir)) {
    return(NULL)
  }
  path <- file.path(dir[[1L]], .dev_dir, .library_file())
  if (file.exists(path)) path
}

# Rebuilds the library build_library() wrote into the sources of `pkg` if it
# is out of date with them, as when the binding package changed since. It
# rebuilds only before a library has loaded, as one cannot be replaced in a
# running process, and only a library built from `pkg` alone, as the sources
# of any others are not recorded; otherwise it warns.
.refresh_dev_library <- function(pkg) {
  if (nzchar(Sys.getenv("JLBIND_LIBRARY", unset = ""))) {
    return(invisible(NULL))
  }
  path <- .dev_library(pkg)
  if (is.null(path)) {
    return(invisible(NULL))
  }
  dir <- dirname(path)
  src <- dirname(dir)
  lib <- .library_state(path)
  loaded <- !is.null(lib$dll)
  # Another client's library may have loaded first; then this one is not
  # used anyway.
  if (loaded && !identical(lib$path, path)) {
    return(invisible(NULL))
  }
  # Once loaded, the library on disk may have been rebuilt since, so the
  # sources are compared with the one that is running.
  reasons <- if (loaded) {
    .dev_stale_reasons(src, lib$clients, lib$build, lib$excluded)
  } else {
    .dev_stale_reasons(
      src,
      .read_clients(dir),
      .read_build(dir),
      .read_excluded(dir)
    )
  }
  if (!length(reasons)) {
    return(invisible(NULL))
  }
  why <- paste0(
    "The development library of ",
    pkg,
    " (",
    path,
    ") is out of date: ",
    paste(reasons, collapse = "; "),
    "."
  )
  if (loaded) {
    warning(why, " ", .rebuild_hint(pkg, lib), call. = FALSE)
    return(invisible(NULL))
  }
  built <- .read_clients(dir)$Package
  if (!identical(built, pkg)) {
    warning(
      why,
      " It was built from ",
      paste(built, collapse = ", "),
      ", so it is not rebuilt automatically; run jlbind::build_library() ",
      "to rebuild it.",
      call. = FALSE
    )
    return(invisible(NULL))
  }
  message(why, " Rebuilding it.")
  # Rebuilt the way it was built.
  build <- .read_build(dir)
  res <- tryCatch(
    build_library(
      src,
      out = dir,
      develop = strsplit(build$Develop, "\n", fixed = TRUE)[[1L]],
      cpu_target = build$CpuTarget,
      julia_args = strsplit(build$JuliaArgs, " ", fixed = TRUE)[[1L]],
      bundle = identical(build$Bundle, "TRUE"),
      private = .is_private(path)
    ),
    error = identity
  )
  if (inherits(res, "error")) {
    warning(
      "Rebuilding the development library of ",
      pkg,
      " failed, so the out-of-date one is used.\n",
      conditionMessage(res),
      call. = FALSE
    )
  }
  invisible(NULL)
}

# Why a library built by build_library() from `built`, as `build`, leaving
# out `excluded` (.read_clients(), .read_build(), .read_excluded()) is out of
# date with the client sources in `src`: a character vector, empty if it is
# up to date or records nothing to compare. Unlike .stale_reasons(), local
# checkouts and other clients are no reason, and the Julia version is not
# checked, as that means running Julia.
.dev_stale_reasons <- function(src, built, build, excluded) {
  if (is.null(built) || is.null(build)) {
    return(character())
  }
  client <- .client_table(list(.client_info(src)))
  status <- .client_status(client, built, excluded)
  status <- status[status$package == client$package, , drop = FALSE]
  build$Develop <- ""
  c(
    .build_reasons(build, NA),
    status$status[!status$status %in% c("ok", "left out")]
  )
}

# Loads the library at `path`, with state `lib`, unless it is already loaded;
# TRUE if it is. `pkg` is the client asking for it.
.load_library <- function(
  pkg = NULL,
  path = .library_path(pkg),
  lib = .library_state(path)
) {
  if (!is.null(lib$dll)) {
    return(TRUE)
  }
  lib$path <- path
  if (!file.exists(path)) {
    lib$problem <- paste0(
      "The compiled Julia library has not been built (it was looked for at ",
      path,
      "). Run jlbind::install_library() to build it; this needs Julia >= 1.13."
    )
    return(FALSE)
  }
  # A library compiled for another computer's CPU can crash R with an illegal
  # instruction. It is loaded anyway, as it may well run, but with a warning,
  # since a crash leaves no error to explain it.
  build <- .read_build(dirname(path))
  mismatch <- .cpu_mismatch(build)
  if (!is.null(mismatch)) {
    warning(
      "The compiled Julia library (",
      path,
      ") was ",
      mismatch,
      ", so it may crash R on this one. If it does: ",
      if (.is_downloaded(build)) {
        "Run jlbind::install_library() to build it for this CPU, then restart R."
      } else {
        .rebuild_hint(pkg, lib)
      },
      " For a library that runs on any CPU, build it with ",
      "`cpu_target = \"generic\"`.",
      call. = FALSE
    )
  }
  # The library links against the Julia that built it, so it stops loading
  # if that Julia is removed (e.g. by a juliaup update).
  .add_julia_bindir(path)
  dll <- tryCatch(.dyn_load(path), error = identity)
  if (inherits(dll, "error")) {
    lib$problem <- paste0(
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
  lib$dll <- dll
  lib$clients <- .read_clients(dirname(path))
  lib$excluded <- .read_excluded(dirname(path))
  lib$build <- .read_build(dirname(path))
  lib$problem <- NULL
  TRUE
}

# The symbols `symbols` of the library `dll` (a DLLInfo, or NULL for null
# ones) as entries of the client `pkg`: external pointers, which jlbind_call()
# calls. They are looked up through the DLL's handle, as every library has the
# DLL name `jlbind`.
.dll_entries <- function(dll, symbols, pkg = "jlbind") {
  .Call(jlbind_entries, dll[["handle"]], as.character(symbols), pkg)
}

# Sets the Julia thread count from JULIA_NUM_THREADS. Must run before the
# first entrypoint call, which initializes Julia.
.set_threads <- function(dll) {
  threads <- .julia_threads()
  if (threads == 1L) {
    return(invisible(NULL))
  }
  set <- .dll_entries(dll, "jlbind_set_julia_threads")[[1L]]
  # 0 asks the library for Julia's own "auto" count.
  status <- .Call(jlbind_set_threads, set, if (is.na(threads)) 0L else threads)
  if (status != 0L) {
    warning(
      "Could not set ",
      if (is.na(threads)) "the \"auto\" number of" else threads,
      " Julia threads; using one.",
      call. = FALSE
    )
  }
  invisible(NULL)
}

# The Julia thread count from JULIA_NUM_THREADS: a count, or NA for "auto",
# which the library resolves as Julia does (the CPU threads available to the
# process). A juliac library ignores the variable itself. Anything after a comma
# (the interactive threadpool) is ignored.
.julia_threads <- function() {
  value <- sub(",.*", "", Sys.getenv("JULIA_NUM_THREADS", unset = ""))
  if (!nzchar(value)) {
    return(1L)
  }
  if (value == "auto") {
    return(NA_integer_)
  }
  n <- suppressWarnings(as.integer(value))
  if (is.na(n) || n < 1L) {
    warning(
      "Ignoring JULIA_NUM_THREADS = \"",
      value,
      "\"; using one Julia thread.",
      call. = FALSE
    )
    return(1L)
  }
  n
}

# R loads a DLL with plain LoadLibrary(), which doesn't look for the DLL's
# dependencies in its own directory. A private library on Windows keeps its
# runtime there: its manifest redirects only libjulia*, which need the
# runtime's other DLLs (libgcc, libstdc++, ...), so R is told to look there.
.dyn_load <- function(path, windows = .Platform$OS.type == "windows") {
  if (windows) {
    dyn.load(path, local = TRUE, now = TRUE, DLLpath = dirname(path))
  } else {
    dyn.load(path, local = TRUE, now = TRUE)
  }
}

# On Windows the library has no RUNPATH, so the directory of the Julia
# runtime it links against (recorded by build.jl next to it, or in its bundle)
# is put on the PATH, where Windows finds libjulia.dll and its dependencies.
# It stays there for the session: Julia opens some runtime libraries later,
# by file name only (PCRE2 at startup and for any Regex, GMP, MPFR), and
# Windows looks for those next to R.exe and on the PATH, not next to
# libjulia. It goes first, so another program's copy (Git's or Rtools'
# ucrt64/bin has a libpcre2-8-0.dll) is not loaded instead. JuliaCall does the
# same.
# A bundle's DLLs are in `bin`, or in `bin/julia` if it was built with Julia
# >= 1.14 started through its 8.3 short path, as R starts programs on Windows
# (JuliaC compares the two spellings as different directories); build.jl
# now avoids that, but libraries built before may still have them there.
.add_julia_bindir <- function(path, windows = .Platform$OS.type == "windows") {
  if (!windows) {
    return(invisible(NULL))
  }
  record <- file.path(dirname(path), "julia_bindir")
  bin <- file.path(dirname(path), "jlbind-bundle", "bin")
  bundled <- c(file.path(bin, "julia"), bin)
  bundled <- bundled[file.exists(file.path(bundled, "libjulia.dll"))]
  if (length(bundled)) {
    bindir <- normalizePath(bundled[[1L]])
  } else if (file.exists(record)) {
    bindir <- normalizePath(
      readLines(record, warn = FALSE)[[1L]],
      mustWork = FALSE
    )
  } else {
    return(invisible(NULL))
  }
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
#' The library is the shared one from [install_library()], unless
#' `JLBIND_LIBRARY` names another, the package was loaded with
#' `pkgload::load_all()` and has one from [build_library()], or
#' [install_library()] built a private library for it. A development library
#' is used if it is private or the package is the first one bound, and it is
#' rebuilt as the package loads if it is out of date with the package's
#' sources, as when its Julia code has changed. A library that has already
#' loaded cannot be replaced, so after a change, restart R. A private library
#' loads alongside the shared one.
#'
#' To run Julia with more threads, set `JULIA_NUM_THREADS` (a number or
#' `"auto"`) before loading the first package that uses jlbind. Each library
#' starts that many.
#'
#' @param pkg The package name.
#'
#' @return Invisibly, `TRUE` if the package is bound and `FALSE` if not.
#' @export
#' @examples
#' \dontrun{
#' # In a package's R/zzz.R, as use_jlbind() writes it
#' .onLoad <- function(libname, pkgname) {
#'   jlbind::bind_client(pkgname)
#' }
#' }
bind_client <- function(pkg) {
  .state$requested <- union(.state$requested, pkg)
  .refresh_dev_library(pkg)
  # A bound package is bound again: pkgload::load_all() reloads its
  # namespace, whose entrypoints then start out unbound.
  .state$bound <- setdiff(.state$bound, pkg)
  ns <- asNamespace(pkg)
  problem <- .client_problem(ns, pkg)
  path <- .library_path(pkg)
  lib <- .library_state(path)
  .state$libraries[[pkg]] <- lib
  .state$problems[[pkg]] <- NULL
  if (is.null(problem)) {
    # Until bound, its entrypoints are null, which give an error that points
    # to check_bound().
    .set_entries(ns, pkg, NULL)
    if (!.load_library(pkg, path, lib)) {
      return(invisible(FALSE))
    }
    problem <- .bind_problem(pkg, lib)
  }
  if (is.null(problem)) {
    res <- tryCatch(.set_entries(ns, pkg, lib$dll), error = identity)
    if (inherits(res, "error")) {
      problem <- paste(conditionMessage(res), .rebuild_hint(pkg, lib))
    }
  }
  .state$problems[[pkg]] <- problem
  if (!is.null(problem)) {
    return(invisible(FALSE))
  }
  .state$bound <- union(.state$bound, pkg)
  invisible(TRUE)
}

# What a client's R/jlbind-wrappers.R (written by update_entrypoints())
# defines in its namespace `ns`: the binding package's name, the names of its
# entrypoints, and the environment the wrappers find them in.
.client_vars <- c(".jlbind_module", ".jlbind_entries", ".jlbind")

# Why the namespace `ns` of `pkg` cannot be bound, or NULL if it can.
.client_problem <- function(ns, pkg) {
  if (all(vapply(.client_vars, exists, TRUE, envir = ns, inherits = FALSE))) {
    return(NULL)
  }
  paste0(
    "Package ",
    pkg,
    " has no jlbind entrypoints; its R/jlbind-wrappers.R is missing (run ",
    "jlbind::use_jlbind() on its sources)."
  )
}

# The C names of the entrypoints `entries` of the binding package `module`:
# `jlbind<n>_<module>_<entry>`, with `n` the number of characters of `module`
# (`_entry_symbol()` in JLBind's rcall.jl), so that names stay distinct when
# module or entry names contain `_`.
.entry_symbols <- function(module, entries) {
  paste0("jlbind", nchar(module, type = "bytes"), "_", module, "_", entries)
}

# Puts the entrypoints of `pkg` into its `.jlbind` environment, along with
# `.call`, jlbind's routine that calls them (src/call.c). They are looked up
# in the library `dll`, or are null with `dll` NULL. The routine is stored as
# its address, as R CMD check reports a client's call to the NativeSymbolInfo
# of another package. `.call` cannot be an entrypoint's name, which is a C
# identifier.
.set_entries <- function(ns, pkg, dll) {
  entries <- ns$.jlbind_entries
  found <- .dll_entries(dll, .entry_symbols(ns$.jlbind_module, entries), pkg)
  env <- ns$.jlbind
  env$.call <- jlbind_call$address
  for (i in seq_along(entries)) {
    assign(entries[[i]], found[[i]], envir = env)
  }
  invisible(NULL)
}

# Why the loaded library with state `lib` cannot serve `pkg`, or NULL if it
# can. A library that records no clients (one built some other way) is
# trusted.
.bind_problem <- function(pkg, lib = .state) {
  built <- lib$clients
  if (is.null(built)) {
    return(NULL)
  }
  version <- as.character(getNamespaceVersion(pkg))
  row <- built[built$Package == pkg, , drop = FALSE]
  excluded <- lib$excluded
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
      ". ",
      .rebuild_hint(pkg, lib)
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
      ". ",
      .rebuild_hint(pkg, lib)
    ))
  }
  NULL
}

# How to get a library that serves `pkg` in place of the one with state
# `lib`, which cannot be replaced in a running process once loaded.
.rebuild_hint <- function(pkg, lib = .state) {
  path <- lib$path
  build <- lib$build
  if (is.null(build) && !is.null(path)) {
    build <- .read_build(dirname(path))
  }
  if (.is_downloaded(build)) {
    return(paste0(
      "Run jlbind::install_library(method = \"download\") to download it ",
      "again, or jlbind::install_library() to build it, then restart R."
    ))
  }
  if (
    identical(path, file.path(.library_dir(), .library_file())) ||
      (!is.null(pkg) && identical(path, .private_library(pkg)))
  ) {
    return("Run jlbind::install_library() to rebuild it, then restart R.")
  }
  # .refresh_dev_library() rebuilds a package's own library as it loads.
  if (
    !is.null(path) &&
      !is.null(pkg) &&
      identical(path, .dev_library(pkg)) &&
      identical(lib$clients$Package, pkg)
  ) {
    return("Restart R and run devtools::load_all() again, which rebuilds it.")
  }
  paste0(
    "Rebuild it (",
    path,
    ") with jlbind::build_library(), then restart R."
  )
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
#' Use `is_bound()` to skip what needs the library when it isn't available:
#' `skip_if_not(jlbind::is_bound("mypkg"))` in tests, and
#' `@examplesIf jlbind::is_bound("mypkg")` in roxygen examples.
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
  problem <- .state$problems[[pkg]]
  if (is.null(problem)) {
    lib <- .state$libraries[[pkg]]
    problem <- if (is.null(lib)) .state$problem else lib$problem
  }
  stop(
    problem,
    "\nRun jlbind::jlbind_sitrep() for a report on the setup.",
    call. = FALSE
  )
}

#' @useDynLib jlbind, .registration = TRUE
NULL
