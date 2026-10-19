#' Report on the jlbind setup
#'
#' Prints a report to run when a package that uses jlbind doesn't work. It
#' shows the Julia that builds the library, the library that is loaded (or
#' would be) and what it was built from, the installed packages that use
#' jlbind and whether the library is current for each, and the Julia thread
#' count. It also works before a library has loaded.
#'
#' @inheritParams install_library
#'
#' @return Invisibly, a list with:
#'   * `julia`: a list with `path` (`NA` if Julia was not found), `source`
#'     (`"argument"`, `"JULIA"` or `"PATH"`), `version` (`NA` if it could not
#'     be run) and `ok` (whether it is Julia 1.14 or later).
#'   * `library`: a list with `path`, `how` (`"loaded"`, `"failed to load"`,
#'     `"JLBIND_LIBRARY"` or `"default"`), `exists`, `build` (how it was
#'     built: the jlbind and Julia versions, when, and whether it is trimmed,
#'     or `NULL`), `problems` (why it should be rebuilt or cannot load; empty
#'     if none) and `objects` (how many Julia objects R holds references to,
#'     or `NULL` if no library is loaded).
#'   * `clients`: a data frame with one row per package that uses jlbind or
#'     that the library was built for, with the columns `package`, `version`
#'     (installed), `built` (the version in the library), `status` (`"ok"`,
#'     `"left out"`, `"not in the library"`, `"built for version <v>"`,
#'     `"Julia code changed"` or `"not installed"`) and `bound`.
#'   * `threads`: a list with `count` (from `JULIA_NUM_THREADS`) and `fixed`
#'     (`TRUE` once a library is loaded, after which the count cannot change).
#' @export
#' @examples
#' jlbind_sitrep()
jlbind_sitrep <- function(julia = NULL) {
  report <- list(julia = .sitrep_julia(julia))
  report$library <- .sitrep_library(report$julia$version)
  dir <- dirname(report$library$path)
  clients <- .client_status(
    jlbind_clients(),
    .read_clients(dir),
    .read_excluded(dir)
  )
  clients$bound <- clients$package %in% .state$bound
  report$clients <- clients
  report$threads <- list(
    count = suppressWarnings(.julia_threads()),
    fixed = !is.null(.state$dll)
  )
  .print_sitrep(report)
  invisible(report)
}

.sitrep_julia <- function(julia = NULL) {
  found <- .locate_julia(julia)
  path <- if (nzchar(found$path)) found$path else NA_character_
  version <- if (is.na(path)) NA else .julia_version(path)
  list(
    path = path,
    source = found$source,
    version = if (is.na(version)) NA_character_ else as.character(version),
    ok = !is.na(version) && version >= "1.14"
  )
}

# The library a client would bind to: the one loaded (or that failed to load),
# else the one from JLBIND_LIBRARY or install_library(). `julia` is the
# version of the Julia that would rebuild it, or NA.
.sitrep_library <- function(julia) {
  how <- if (!is.null(.state$dll)) {
    "loaded"
  } else if (!is.null(.state$path)) {
    "failed to load"
  } else if (nzchar(Sys.getenv("JLBIND_LIBRARY"))) {
    "JLBIND_LIBRARY"
  } else {
    "default"
  }
  path <- if (how %in% c("loaded", "failed to load")) {
    .state$path
  } else {
    .library_path()
  }
  dir <- dirname(path)
  exists <- file.exists(path)
  build <- if (exists) .read_build(dir)
  bindir <- file.path(dir, "julia_bindir")
  bindir <- if (exists && file.exists(bindir)) {
    readLines(bindir, warn = FALSE)[[1L]]
  }
  problems <- as.character(c(
    if (!exists) "it has not been built",
    if (how == "failed to load") .state$problem,
    if (!is.null(build)) .build_reasons(build, julia),
    if (!is.null(bindir) && !dir.exists(bindir)) {
      paste0("the Julia it was built with (", bindir, ") no longer exists")
    }
  ))
  list(
    path = path,
    how = how,
    exists = exists,
    build = build[c("jlbind", "Julia", "Built", "Trim")],
    problems = problems,
    objects = .object_count()
  )
}

# How many Julia objects R holds references to (RRefs), or NULL if no library
# is loaded.
.object_count <- function() {
  dll <- .state$dll
  if (is.null(dll)) {
    return(NULL)
  }
  count <- getNativeSymbolInfo("JLBind_object_count_0", dll)
  objects <- .Call(count)
  if (inherits(objects, "jlbind_error")) {
    stop(objects[[1L]], call. = FALSE)
  }
  objects
}

.print_sitrep <- function(report) {
  utf8 <- isTRUE(l10n_info()[["UTF-8"]])
  mark <- function(ok) {
    if (utf8) ifelse(ok, "\u2714", "\u2716") else ifelse(ok, "v", "x")
  }
  rule <- if (utf8) "\u2500\u2500" else "--"
  line <- function(...) cat(..., "\n", sep = "")
  head <- function(title) line(rule, " ", title)

  head("Julia (for building the library)")
  julia <- report$julia
  if (is.na(julia$path)) {
    line(
      mark(FALSE),
      " not found: install Julia >= 1.14, or set the JULIA environment ",
      "variable to its path"
    )
  } else if (is.na(julia$version)) {
    line(mark(FALSE), " ", julia$path, " (from ", julia$source, ") won't run")
  } else {
    line(
      mark(julia$ok),
      " Julia ",
      julia$version,
      " at ",
      julia$path,
      " (from ",
      julia$source,
      ")",
      if (!julia$ok) "; jlbind needs Julia >= 1.14"
    )
  }

  head("Library")
  lib <- report$library
  ok <- !length(lib$problems)
  line(mark(ok), " ", lib$path, " (", lib$how, ")")
  build <- lib$build
  if (!is.null(build)) {
    line(
      "  built ",
      build$Built,
      " by jlbind ",
      build$jlbind,
      " with Julia ",
      build$Julia,
      if (identical(build$Trim, "FALSE")) ", untrimmed"
    )
  }
  if (!is.null(lib$objects)) {
    line(
      "  ",
      lib$objects,
      " Julia object",
      if (lib$objects != 1L) "s",
      " referenced from R"
    )
  }
  for (p in lib$problems) {
    line(mark(FALSE), " ", p)
  }

  head("Packages that use jlbind")
  clients <- report$clients
  if (!nrow(clients)) {
    line("  none installed")
  }
  for (i in seq_len(nrow(clients))) {
    row <- clients[i, ]
    status <- row$status
    if (row$bound) {
      status <- paste0(status, ", bound")
    }
    problem <- .state$problems[[row$package]]
    line(
      mark(row$status %in% c("ok", "left out") && is.null(problem)),
      " ",
      row$package,
      if (!is.na(row$version)) paste0(" ", row$version),
      ": ",
      status
    )
    if (!is.null(problem)) {
      line("  ", problem)
    }
  }

  stale <- !lib$exists ||
    length(lib$problems) ||
    !all(clients$status %in% c("ok", "left out"))
  if (stale && nrow(clients)) {
    line(
      "  ",
      if (lib$how == "default") {
        "Run jlbind::install_library() to rebuild the library"
      } else {
        "Rebuild the library with jlbind::build_library()"
      },
      if (!is.null(.state$dll)) ", then restart R" else ""
    )
  }

  head("Threads")
  threads <- report$threads
  line(
    "  ",
    threads$count,
    " Julia thread",
    if (threads$count != 1L) "s",
    " (JULIA_NUM_THREADS",
    if (nzchar(Sys.getenv("JULIA_NUM_THREADS"))) {
      paste0(" = ", Sys.getenv("JULIA_NUM_THREADS"))
    } else {
      " unset"
    },
    ")",
    if (threads$fixed) "; fixed, as the library is loaded"
  )
  invisible(NULL)
}
