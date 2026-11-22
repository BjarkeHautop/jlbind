#' Report on the jlbind setup
#'
#' Prints a report to run when a package that uses jlbind doesn't work. It
#' shows the Julia that builds the libraries, the shared library that is
#' loaded (or would be) and what it was built from, any private libraries
#' (see `private` in [install_library()]), the installed packages that use
#' jlbind and whether their library is current for each, and the Julia thread
#' count. It also works before a library has loaded.
#'
#' @inheritParams install_library
#'
#' @return Invisibly, a list with:
#'   * `julia`: a list with `path` (`NA` if Julia was not found), `source`
#'     (`"argument"`, `"JULIA"` or `"PATH"`), `version` (`NA` if it could not
#'     be run) and `ok` (whether it is Julia 1.13 or later).
#'   * `library`: the shared library, a list with `path`, `how` (`"loaded"`,
#'     `"failed to load"`, `"JLBIND_LIBRARY"` or `"default"`), `exists`,
#'     `build` (how it was built: the jlbind and Julia versions, when, whether
#'     it is trimmed, the CPU target and the CPU it was built on, any extra
#'     Julia arguments, whether it is a bundle and the salt of a private
#'     runtime, or `NULL`), `problems` (why it should be rebuilt or cannot
#'     load; empty if none) and `objects` (how many Julia objects R holds
#'     references to, or `NULL` if it isn't loaded).
#'   * `private`: the private libraries packages use, each a list like
#'     `library`, with `how` `"loaded"`, `"failed to load"` or `"private"`.
#'   * `clients`: a data frame with one row per package that uses jlbind or
#'     that a library was built for, with the columns `package`, `version`
#'     (installed), `built` (the version in its library), `status` (`"ok"`,
#'     `"left out"`, `"not in the library"`, `"built for version <v>"`,
#'     `"Julia code changed"` or `"not installed"`), `bound` and `library`
#'     (the path of its library).
#'   * `threads`: a list with `count` (from `JULIA_NUM_THREADS`, in each
#'     library) and `fixed` (`TRUE` once a library is loaded, after which the
#'     count cannot change).
#' @export
#' @examples
#' jlbind_sitrep()
jlbind_sitrep <- function(julia = NULL) {
  report <- list(julia = .sitrep_julia(julia))
  report$library <- .sitrep_library(report$julia$version)
  installed <- jlbind_clients()
  paths <- vapply(installed$package, .client_library_path, "")
  private <- vapply(unique(paths), .is_private, TRUE)
  private <- names(private)[private]
  shared <- installed[!paths %in% private, , drop = FALSE]
  report$private <- lapply(private, function(path) {
    .sitrep_library(report$julia$version, path, .library_state(path))
  })
  dir <- dirname(report$library$path)
  clients <- .client_status(shared, .read_clients(dir), .read_excluded(dir))
  clients$library <- rep(report$library$path, nrow(clients))
  for (path in private) {
    dir <- dirname(path)
    status <- .client_status(
      installed[paths == path, , drop = FALSE],
      .read_clients(dir),
      .read_excluded(dir)
    )
    status$library <- rep(path, nrow(status))
    clients <- rbind(clients, status)
  }
  # A package not installed is reported once, by the shared library.
  clients <- clients[
    clients$status != "not installed" | clients$library == report$library$path,
    ,
    drop = FALSE
  ]
  rownames(clients) <- NULL
  clients$bound <- clients$package %in% .state$bound
  report$clients <- clients[
    c("package", "version", "built", "status", "bound", "library")
  ]
  report$threads <- list(
    count = suppressWarnings(.julia_threads()),
    fixed = length(.loaded_libraries()) > 0L
  )
  .print_sitrep(report)
  invisible(report)
}

# The path of the library the installed client `pkg` binds to, or would.
.client_library_path <- function(pkg) {
  lib <- .state$libraries[[pkg]]
  if (!is.null(lib) && !is.null(lib$path)) {
    return(lib$path)
  }
  .library_path(pkg)
}

.sitrep_julia <- function(julia = NULL) {
  found <- .locate_julia(julia)
  path <- if (nzchar(found$path)) found$path else NA_character_
  version <- if (is.na(path)) NA else .julia_version(path)
  list(
    path = path,
    source = found$source,
    version = if (is.na(version)) NA_character_ else as.character(version),
    ok = !is.na(version) && version >= "1.13"
  )
}

# The library with state `lib` at `path`. For the shared library, that is the
# one loaded (or that failed to load), else the one from JLBIND_LIBRARY or
# install_library(). `julia` is the version of the Julia that would rebuild
# it, or NA.
.sitrep_library <- function(julia, path = NULL, lib = .state) {
  how <- if (!is.null(lib$dll)) {
    "loaded"
  } else if (!is.null(lib$path)) {
    "failed to load"
  } else if (!is.null(path)) {
    "private"
  } else if (nzchar(Sys.getenv("JLBIND_LIBRARY"))) {
    "JLBIND_LIBRARY"
  } else {
    "default"
  }
  if (how %in% c("loaded", "failed to load")) {
    path <- lib$path
  } else if (is.null(path)) {
    path <- .library_path()
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
    if (how == "failed to load") lib$problem,
    if (!is.null(build)) .build_reasons(build, julia),
    if (!is.null(bindir) && !dir.exists(bindir)) {
      paste0("the Julia it was built with (", bindir, ") no longer exists")
    }
  ))
  list(
    path = path,
    how = how,
    exists = exists,
    build = build[c(
      "jlbind",
      "Julia",
      "Built",
      "Trim",
      "CpuTarget",
      "CPU",
      "JuliaArgs",
      "Bundle",
      "Private"
    )],
    problems = problems,
    objects = if (!is.null(lib$dll)) .object_count(lib)
  )
}

#' Count the Julia objects R holds
#'
#' The number of Julia objects that R currently holds references to (the
#' `RRef`s returned by the packages that use jlbind), across all of these
#' packages. An object is released once R garbage-collects every reference to
#' it, so this is useful for checking that a package doesn't leak objects.
#'
#' @return A number, or `NULL` if no Julia library is loaded.
#' @export
#' @examples
#' object_count()
object_count <- function() {
  libs <- .loaded_libraries()
  if (!length(libs)) {
    return(NULL)
  }
  sum(vapply(libs, function(lib) as.numeric(.object_count(lib)), 0))
}

# How many Julia objects R holds references to in the library with state
# `lib`, which is loaded.
.object_count <- function(lib) {
  count <- .dll_entries(lib$dll, .entry_symbols("JLBind", "object_count"))[[1L]]
  .External(jlbind_call, count)
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
      " not found: install Julia >= 1.13, or set the JULIA environment ",
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
      if (!julia$ok) "; jlbind needs Julia >= 1.13"
    )
  }

  head("Library")
  .print_library(report$library, line, mark)
  for (lib in report$private) {
    pkgs <- report$clients$package[report$clients$library == lib$path]
    head(paste0("Private library of ", paste(pkgs, collapse = ", ")))
    .print_library(lib, line, mark)
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
    if (row$library != report$library$path) {
      status <- paste0(status, ", private library")
    }
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

  # How to rebuild each library that is stale for its clients.
  hint <- function(lib, installed) {
    rows <- clients$library == lib$path
    stale <- !lib$exists ||
      length(lib$problems) ||
      !all(clients$status[rows] %in% c("ok", "left out"))
    if (!stale || !any(rows)) {
      return(NULL)
    }
    if (installed) {
      "Run jlbind::install_library() to rebuild the library"
    } else {
      "Rebuild the library with jlbind::build_library()"
    }
  }
  hints <- unique(c(
    hint(
      report$library,
      identical(report$library$path, file.path(.library_dir(), .library_file()))
    ),
    unlist(lapply(report$private, function(p) {
      hint(p, .is_installed_private(p$path))
    }))
  ))
  for (h in hints) {
    line("  ", h, if (report$threads$fixed) ", then restart R" else "")
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
    if (length(report$private)) ", in each library",
    if (threads$fixed) "; fixed, as a library is loaded"
  )
  invisible(NULL)
}

# Whether `path` is a private library install_library() built.
.is_installed_private <- function(path) {
  identical(
    normalizePath(dirname(dirname(path)), mustWork = FALSE),
    normalizePath(.private_root(), mustWork = FALSE)
  )
}

.print_library <- function(lib, line, mark) {
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
      if (identical(build$Trim, "FALSE")) ", untrimmed",
      if (!is.null(build$CpuTarget) && !is.na(build$CpuTarget)) {
        paste0(", for CPU target \"", build$CpuTarget, "\"")
      },
      if (
        identical(build$CpuTarget, "native") &&
          !is.na(build$CPU) &&
          nzchar(build$CPU)
      ) {
        paste0(" (", build$CPU, ")")
      },
      if (
        !is.null(build$JuliaArgs) &&
          !is.na(build$JuliaArgs) &&
          nzchar(build$JuliaArgs)
      ) {
        paste0(", with Julia arguments \"", build$JuliaArgs, "\"")
      },
      if (
        !is.null(build$Private) &&
          !is.na(build$Private) &&
          nzchar(build$Private)
      ) {
        paste0(", with a private Julia runtime (", build$Private, ")")
      } else if (identical(unname(build$Bundle), "TRUE")) {
        ", bundled"
      }
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
}
