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
#' [check_bound()] says why. See `vignette("using-clients", "jlbind")` for
#' details.
#'
#' The library is rebuilt only if it is out of date: built from other versions
#' of the packages or their Julia code, by another version of jlbind or Julia,
#' or with other options. If a library is already loaded, restart R to use the
#' new one.
#'
#' The library is compiled for this computer's CPU, and jlbind won't load it on
#' another. If one R library is used from computers with different CPUs, as on
#' a cluster, use `cpu_target = "generic"`.
#'
#' @param packages Names of the installed packages to build. By default, every
#'   package listed by [jlbind_clients()]. The others aren't bound.
#' @param julia Path to the `julia` executable. By default, the `JULIA`
#'   environment variable, or `julia` on the `PATH`.
#' @param ask If `TRUE`, ask before building. Defaults to [interactive()].
#' @param force If `TRUE`, rebuild even if the library is up to date. Always on
#'   with `versions = "compat"` or `develop`.
#' @param versions Where the Julia dependency versions come from. `"manifest"`
#'   keeps the versions in the first package's `Manifest.toml` where the other
#'   packages' `[compat]` bounds allow. `"compat"` ignores the manifests and
#'   lets Julia's resolver choose versions from the `[compat]` bounds alone.
#' @param develop Paths to local Julia packages to use instead of their released
#'   versions.
#' @param cpu_target The CPUs to compile for, as Julia's `--cpu-target`.
#'   By default, `JULIA_CPU_TARGET`, or `"native"`. `"generic"` runs on any CPU,
#'   but numeric code can be slower.
#' @param julia_args For advanced use: extra Julia command-line options for
#'   compiling the library, such as `"-O3"`. jlbind passes `-g0` (no debug
#'   info), which these can override (e.g. `"-g1"`), but not the options it
#'   relies on: `--trim`, `--output-*` and `--compile-ccallable`. By default,
#'   `JLBIND_JULIA_ARGS` split at spaces.
#' @param bundle If `TRUE`, copy the Julia runtime next to the library, so that
#'   it runs without Julia installed. This makes the library much larger, and is
#'   only useful for giving a library to people without Julia, who set
#'   `JLBIND_LIBRARY` to it. They also need a `cpu_target` other than `"native"`.
#'
#' @return The path to the library (invisibly), or `NULL` if there was nothing
#'   to build.
#' @export
#' @examples
#' \dontrun{
#' install_library()
#'
#' # With a local checkout of a Julia dependency
#' install_library(develop = "~/dev/SomePackage.jl")
#'
#' # Only two of the installed packages
#' install_library(packages = c("pkgA", "pkgB"))
#'
#' # For an R library shared by computers with different CPUs
#' install_library(cpu_target = "generic")
#' }
install_library <- function(
  packages = NULL,
  julia = NULL,
  ask = interactive(),
  force = FALSE,
  versions = c("manifest", "compat"),
  develop = NULL,
  cpu_target = NULL,
  julia_args = NULL,
  bundle = FALSE
) {
  versions <- match.arg(versions)
  cpu_target <- .cpu_target(cpu_target)
  julia_args <- .julia_args(julia_args)
  .check_bundle(bundle)
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
  dir <- .library_dir()
  path <- file.path(dir, .library_file())
  julia <- .find_julia(julia)
  if (
    !force &&
      versions == "manifest" &&
      !length(develop) &&
      .up_to_date(
        dir,
        clients,
        .julia_version(julia),
        cpu_target,
        julia_args,
        bundle
      )
  ) {
    message(
      "The compiled Julia library is up to date (",
      path,
      "); use `force = TRUE` to rebuild it."
    )
    .bind_requested()
    return(invisible(path))
  }

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
  .build(clients, out, julia, versions, develop, cpu_target, julia_args, bundle)

  # A loaded library cannot be deleted on Windows, but it can be renamed, so
  # the old build is moved aside first; whatever cannot be removed now is
  # pruned on the next build.
  old <- NULL
  if (dir.exists(dir)) {
    old <- tempfile("old-", tmpdir = root)
    if (!file.rename(dir, old)) {
      stop("Could not replace the library in ", dir, ".", call. = FALSE)
    }
  }
  if (!file.rename(out, dir)) {
    # Put the old library back rather than leave none.
    if (!is.null(old)) {
      file.rename(old, dir)
    }
    stop("Could not move the library into ", dir, ".", call. = FALSE)
  }
  .prune_builds(root)

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

#' Remove the Julia library
#'
#' Deletes the library built by [install_library()], with everything else
#' jlbind stores in `tools::R_user_dir("jlbind", "data")`. Packages that use
#' jlbind can't call their Julia code until you run [install_library()] again.
#'
#' Libraries that [build_library()] wrote elsewhere are left alone, as are the
#' Julia packages that builds downloaded into Julia's package depot; run
#' `Pkg.gc()` in Julia to remove the ones nothing uses.
#'
#' @param ask If `TRUE`, ask before removing. Defaults to [interactive()].
#'
#' @return `TRUE` if there was a library to remove, otherwise `FALSE`,
#'   invisibly.
#' @export
#' @examples
#' \dontrun{
#' remove_library()
#' }
remove_library <- function(ask = interactive()) {
  dir <- .library_dir()
  root <- dirname(dir)
  if (!dir.exists(root)) {
    message("There is no compiled Julia library to remove.")
    return(invisible(FALSE))
  }
  loaded <- identical(.state$path, file.path(dir, .library_file()))
  # A loaded DLL cannot be deleted on Windows, and deleting the rest would
  # leave a library that cannot be used.
  if (loaded && .Platform$OS.type == "windows") {
    stop(
      "The library is loaded in this R session. Restart R and run ",
      "jlbind::remove_library() before loading a package that uses jlbind.",
      call. = FALSE
    )
  }
  if (isTRUE(ask)) {
    choice <- utils::menu(
      c("Yes", "No"),
      title = paste0("Remove the compiled Julia library in ", root, "?")
    )
    if (choice != 1L) {
      message("Cancelled.")
      return(invisible(FALSE))
    }
  }
  unlink(root, recursive = TRUE)
  if (dir.exists(root)) {
    stop(
      "Could not remove all of ",
      root,
      ". If the library is loaded in another R session, close it and try ",
      "again.",
      call. = FALSE
    )
  }
  message(
    "Removed the compiled Julia library.",
    if (loaded) {
      " Packages bound to it keep working until R is restarted."
    }
  )
  invisible(TRUE)
}

#' Build a Julia library from specific packages
#'
#' Like [install_library()], but compiles only `packages` and writes the library
#' to `out`, for package development. By default, it builds the package in the
#' working directory into its `.jlbind/` directory, which `devtools::load_all()`
#' then uses instead of the library from [install_library()]. To use a library
#' written elsewhere, set `JLBIND_LIBRARY` to its path before loading the
#' package.
#'
#' @param packages Paths to package sources or installed packages, or names of
#'   installed packages. An entry containing a `/` (or `\` on Windows), or
#'   that is `"."` or `".."`, is a path; any other is a package name, so write
#'   `"./mypkg"` for the sources in the `mypkg` directory.
#' @param out Directory to write the library to. Defaults to `.jlbind/` in the
#'   sources of `packages`, which must then be a single path.
#' @inheritParams install_library
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
  versions = c("manifest", "compat"),
  develop = NULL,
  cpu_target = NULL,
  julia_args = NULL,
  bundle = FALSE
) {
  versions <- match.arg(versions)
  cpu_target <- .cpu_target(cpu_target)
  julia_args <- .julia_args(julia_args)
  .check_bundle(bundle)
  is_path <- .is_path(packages)
  if (is.null(out)) {
    if (length(packages) != 1L || !is_path) {
      stop(
        "`out` is needed unless `packages` is a single path.",
        call. = FALSE
      )
    }
    out <- file.path(packages, .dev_dir)
  }
  infos <- Map(
    function(p, path) .client_info(if (path) p else find.package(p)),
    packages,
    is_path
  )
  clients <- .client_table(infos)
  julia <- .find_julia(julia)
  .build(clients, out, julia, versions, develop, cpu_target, julia_args, bundle)
  invisible(file.path(normalizePath(out), .library_file()))
}

.check_bundle <- function(bundle) {
  if (!isTRUE(bundle) && !isFALSE(bundle)) {
    stop("`bundle` must be TRUE or FALSE.", call. = FALSE)
  }
  invisible(NULL)
}

# Options of the compile that jlbind sets itself: the entrypoints are exported
# from a library (--output-lib, --compile-ccallable), trimming is up to the
# clients (--trim, with --experimental), and the CPU target is `cpu_target`.
# `--bundle` and `--privatize` are options of JuliaC, which Julia doesn't know.
.fixed_julia_args <- c(
  "--trim",
  "--output",
  "--compile-ccallable",
  "--experimental",
  "--cpu-target",
  "-C",
  "--bundle",
  "--privatize"
)

# The extra `julia_args` to build with: the argument, else JLBIND_JULIA_ARGS
# split at spaces, else none.
.julia_args <- function(julia_args = NULL) {
  if (is.null(julia_args)) {
    env <- trimws(Sys.getenv("JLBIND_JULIA_ARGS", unset = ""))
    julia_args <- if (nzchar(env)) strsplit(env, "\\s+")[[1L]] else character()
  }
  if (!is.character(julia_args) || anyNA(julia_args)) {
    stop("`julia_args` must be a character vector.", call. = FALSE)
  }
  bad <- julia_args[
    !startsWith(julia_args, "-") |
      Reduce(`|`, lapply(.fixed_julia_args, startsWith, x = julia_args), FALSE)
  ]
  if (length(bad)) {
    stop(
      "Cannot build with `julia_args` ",
      paste(bad, collapse = ", "),
      ": each must be an option (starting with `-`), and not one jlbind sets ",
      "itself (",
      paste0(.fixed_julia_args, collapse = ", "),
      "; use `cpu_target` for the CPU target and `bundle` for a bundle).",
      call. = FALSE
    )
  }
  julia_args
}

# The `cpu_target` to build for: the argument, else JULIA_CPU_TARGET, else
# "native".
.cpu_target <- function(cpu_target = NULL) {
  if (is.null(cpu_target)) {
    cpu_target <- Sys.getenv("JULIA_CPU_TARGET", unset = "")
    if (!nzchar(cpu_target)) {
      cpu_target <- "native"
    }
  }
  if (
    !is.character(cpu_target) ||
      length(cpu_target) != 1L ||
      is.na(cpu_target) ||
      !nzchar(cpu_target)
  ) {
    stop("`cpu_target` must be a single string.", call. = FALSE)
  }
  cpu_target
}

# This computer's CPU model, as the operating system names it, or NA if it
# cannot be told. Recorded with a library built for the "native" CPU, which
# may crash on another one; it is read without running Julia, as it is
# checked before loading the library.
.cpu_model <- function(sysname = Sys.info()[["sysname"]]) {
  model <- tryCatch(
    switch(
      sysname,
      Linux = {
        info <- readLines("/proc/cpuinfo", warn = FALSE)
        # "model name" on x86; ARM gives the implementer and part instead.
        keys <- c("model name", "CPU implementer", "CPU part")
        values <- vapply(
          keys,
          function(key) {
            line <- grep(paste0("^", key, "\\s*:"), info, value = TRUE)
            if (length(line)) trimws(sub("^[^:]*:", "", line[[1L]])) else ""
          },
          ""
        )
        if (nzchar(values[[1L]])) {
          values[[1L]]
        } else {
          paste(values[-1L], collapse = " ")
        }
      },
      Darwin = system2(
        "sysctl",
        c("-n", "machdep.cpu.brand_string"),
        stdout = TRUE,
        stderr = FALSE
      )[[1L]],
      Windows = Sys.getenv("PROCESSOR_IDENTIFIER"),
      ""
    ),
    error = function(e) "",
    warning = function(w) ""
  )
  model <- trimws(model)
  if (length(model) == 1L && nzchar(model)) model else NA_character_
}

# Which of `x` build_library() takes as paths rather than package names.
.is_path <- function(x) {
  x %in%
    c(".", "..") |
    grepl("/", x, fixed = TRUE) |
    (.Platform$OS.type == "windows" & grepl("\\", x, fixed = TRUE))
}

# Compiles `clients` (a .client_table()) into `out`, with the metadata the
# runtime checks clients against.
.build <- function(
  clients,
  out,
  julia,
  versions = "manifest",
  develop = NULL,
  cpu_target = "native",
  julia_args = character(),
  bundle = FALSE
) {
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
  if (bundle && grepl("native", cpu_target, fixed = TRUE)) {
    message(
      "Building a bundle for CPU target \"",
      cpu_target,
      "\", which jlbind only loads on this CPU model. To give it to others, ",
      "use another `cpu_target`, such as \"generic\"."
    )
  }
  dir.create(out, recursive = TRUE, showWarnings = FALSE)
  script <- system.file("julia", "build.jl", package = "jlbind")
  status <- .run_julia(
    julia,
    c(
      shQuote(script),
      shQuote(out),
      if (versions == "compat") "--update",
      if (!trim) "--no-trim",
      if (bundle) "--bundle",
      shQuote(paste0("--cpu-target=", cpu_target)),
      if (length(julia_args)) {
        shQuote(paste0("--julia-arg=", julia_args))
      },
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
    Module = clients$module,
    Hash = clients$hash
  )
  write.dcf(meta[!left_out, , drop = FALSE], file.path(out, "clients"))
  excluded <- meta[left_out, , drop = FALSE]
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
  cpu <- .cpu_model()
  write.dcf(
    data.frame(
      jlbind = as.character(utils::packageVersion("jlbind")),
      Julia = as.character(.julia_version(julia)),
      Built = format(Sys.time(), tz = "UTC", usetz = TRUE),
      Trim = trim,
      # Built with local checkouts: not what a plain install_library() builds.
      Develop = paste(develop, collapse = "\n"),
      CpuTarget = cpu_target,
      CPU = if (is.na(cpu)) "" else cpu,
      JuliaArgs = paste(julia_args, collapse = " "),
      Bundle = bundle
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
      "cannot be resolved. See the output of jlbind::install_library()."
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
    " instead, run jlbind::install_library(packages = ",
    .deparse_chr(keep),
    ") and restart R."
  )
}

.deparse_chr <- function(x) {
  x <- paste0('"', x, '"')
  if (length(x) == 1L) x else paste0("c(", paste(x, collapse = ", "), ")")
}

# Removes what earlier builds left in `root`: libraries moved aside by
# install_library(), and the directories of builds that did not finish (R was
# killed mid-build). A build directory is only removed once it is a day old,
# since another R session may still be building in it.
.prune_builds <- function(root, now = Sys.time()) {
  entries <- list.files(root, "^(old|build)-", full.names = TRUE)
  age <- difftime(now, file.mtime(entries), units = "days")
  stale <- startsWith(basename(entries), "old-") | age > 1
  unlink(entries[stale], recursive = TRUE)
  invisible(NULL)
}

# Where install_library() builds the library.
.library_dir <- function() {
  file.path(tools::R_user_dir("jlbind", "data"), "library")
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
# Version, Module, Hash), or NULL if it records none.
.read_clients <- function(dir) {
  file <- file.path(dir, "clients")
  if (!file.exists(file)) {
    return(NULL)
  }
  as.data.frame(read.dcf(file), stringsAsFactors = FALSE)
}

# The clients left out of the library in `dir` (a data frame with Package,
# Version, Module, Hash, Conflicts), or NULL if it records none.
.read_excluded <- function(dir) {
  file <- file.path(dir, "excluded")
  if (!file.exists(file) || !length(readLines(file, warn = FALSE))) {
    return(NULL)
  }
  as.data.frame(read.dcf(file), stringsAsFactors = FALSE)
}

# How the library in `dir` was built (a list with jlbind, Julia, Built, Trim,
# Develop, CpuTarget, CPU, JuliaArgs and Bundle, NA where not recorded), or NULL
# if it records nothing.
.read_build <- function(dir) {
  file <- file.path(dir, "build")
  if (!file.exists(file)) {
    return(NULL)
  }
  fields <- c(
    "jlbind",
    "Julia",
    "Built",
    "Trim",
    "Develop",
    "CpuTarget",
    "CPU",
    "JuliaArgs",
    "Bundle"
  )
  as.list(read.dcf(file, fields = fields)[1L, ])
}

# Was the library in `dir` built by this version of jlbind and Julia version
# `julia`, for `cpu_target`, with `julia_args`, as a bundle or not (`bundle`),
# from exactly these versions of these clients, with the same binding package
# files (counting the clients it left out), and with no local checkouts?
.up_to_date <- function(
  dir,
  clients,
  julia,
  cpu_target = NA,
  julia_args = NULL,
  bundle = NA
) {
  !length(.stale_reasons(dir, clients, julia, cpu_target, julia_args, bundle))
}

# Why the library in `dir` is not what install_library() would build from
# `clients` with Julia version `julia` for `cpu_target` with `julia_args`, as a
# bundle or not (`bundle`) (each skipped if NA or NULL): a character vector,
# empty if it is up to date.
.stale_reasons <- function(
  dir,
  clients,
  julia,
  cpu_target = NA,
  julia_args = NULL,
  bundle = NA
) {
  built <- .read_clients(dir)
  build <- .read_build(dir)
  if (
    is.null(built) ||
      is.null(build) ||
      !file.exists(file.path(dir, .library_file()))
  ) {
    return("it has not been built")
  }
  status <- .client_status(clients, built, .read_excluded(dir))
  c(
    .build_reasons(build, julia, cpu_target, julia_args, bundle),
    paste0(status$package, ": ", status$status)[
      !status$status %in% c("ok", "left out")
    ]
  )
}

# Why a library built as `build` (.read_build()) is out of date regardless of
# its clients, for Julia version `julia`, `cpu_target`, `julia_args` and
# `bundle` (each skipped if NA or NULL). A bundle doesn't use the installed
# Julia, so another version of it is no reason.
.build_reasons <- function(
  build,
  julia,
  cpu_target = NA,
  julia_args = NULL,
  bundle = NA
) {
  # Libraries from before `julia_args` were built with none.
  built_args <- build$JuliaArgs
  if (is.null(built_args) || is.na(built_args)) {
    built_args <- ""
  }
  # Likewise, libraries from before `bundle` aren't bundles.
  bundled <- identical(unname(build$Bundle), "TRUE")
  julia_args <- if (!is.null(julia_args)) paste(julia_args, collapse = " ")
  jlbind <- as.character(utils::packageVersion("jlbind"))
  c(
    if (!identical(build$jlbind, jlbind)) {
      paste0("built by jlbind ", build$jlbind, ", not ", jlbind)
    },
    if (
      !bundled && !is.na(julia) && !identical(build$Julia, as.character(julia))
    ) {
      paste0("built with Julia ", build$Julia, ", not ", julia)
    },
    if (!is.na(bundle) && !identical(bundled, bundle)) {
      if (bundled) "built as a bundle" else "not built as a bundle"
    },
    if (!is.na(cpu_target) && !identical(build$CpuTarget, cpu_target)) {
      paste0(
        "built for ",
        if (is.na(build$CpuTarget)) {
          "Julia's default CPU targets"
        } else {
          paste0("CPU target \"", build$CpuTarget, "\"")
        },
        ", not \"",
        cpu_target,
        "\""
      )
    },
    .cpu_mismatch(build),
    if (!is.null(julia_args) && !identical(built_args, julia_args)) {
      paste0(
        "built with Julia arguments \"",
        built_args,
        "\", not \"",
        julia_args,
        "\""
      )
    },
    if (!is.na(build$Develop) && nzchar(build$Develop)) {
      "built with local checkouts (`develop`)"
    }
  )
}

# Why a library built as `build` (.read_build()) may crash on this computer:
# it was compiled for the native CPU of a computer with another CPU model.
# NULL if not, or if either CPU is unknown.
.cpu_mismatch <- function(build, cpu = .cpu_model()) {
  target <- build$CpuTarget
  if (
    is.null(target) ||
      is.na(target) ||
      !grepl("native", target, fixed = TRUE) ||
      is.null(build$CPU) ||
      is.na(build$CPU) ||
      !nzchar(build$CPU) ||
      is.na(cpu) ||
      identical(build$CPU, cpu)
  ) {
    return(NULL)
  }
  paste0("built for another CPU (", build$CPU, ", not ", cpu, ")")
}

# How a library built from `built` and leaving out `excluded`
# (.read_clients(), .read_excluded()) stands for each of `clients` (a
# .client_table()), and for each package it was built for that is not one of
# them: a data frame with package, version (installed), built (the version the
# library has) and status: "ok", "left out", "not in the library", "built for
# version <v>", "Julia code changed" or "not installed".
.client_status <- function(clients, built, excluded) {
  col <- function(df, name) {
    if (is.null(df[[name]])) rep(NA_character_, NROW(df)) else df[[name]]
  }
  rec <- list(
    package = c(col(built, "Package"), col(excluded, "Package")),
    version = c(col(built, "Version"), col(excluded, "Version")),
    hash = c(col(built, "Hash"), col(excluded, "Hash")),
    left = c(rep(FALSE, NROW(built)), rep(TRUE, NROW(excluded)))
  )
  hash <- col(clients, "hash")
  j <- match(clients$package, rec$package)
  status <- ifelse(
    is.na(j),
    "not in the library",
    ifelse(
      rec$version[j] != clients$version,
      paste0("built for version ", rec$version[j]),
      ifelse(
        !vapply(
          seq_along(j),
          function(i) identical(rec$hash[j[i]], hash[i]),
          TRUE
        ),
        "Julia code changed",
        ifelse(rec$left[j], "left out", "ok")
      )
    )
  )
  gone <- setdiff(rec$package, clients$package)
  data.frame(
    package = c(clients$package, gone),
    version = c(clients$version, rep(NA_character_, length(gone))),
    built = c(rec$version[j], rec$version[match(gone, rec$package)]),
    status = c(status, rep("not installed", length(gone))),
    stringsAsFactors = FALSE
  )
}
