#' Build the Julia library
#'
#' Compiles the Julia code of every installed package that uses jlbind into one
#' shared library, stored in `tools::R_user_dir("jlbind", "cache")`. Run this
#' after you install or update one of those packages. You need Julia 1.13 or
#' later. The first build downloads and compiles the Julia dependencies, which
#' can take a few minutes.
#'
#' All packages in the shared library share one Julia environment. By default,
#' the dependencies get the versions in the first package's `Manifest.toml`.
#' If two packages conflict, the one listed later by [jlbind_clients()] is left
#' out, and [check_bound()] says why. To use it anyway, give it a library of
#' its own with `private`, which has its own copy of the Julia runtime and
#' takes more disk space and memory, or build it into a separate library with
#' [build_library()] for separate R sessions. See
#' `vignette("libraries", "jlbind")` for how these compare.
#'
#' A library is rebuilt only if it is out of date: built from other versions
#' of the packages or their Julia code, with another version of Julia, by an
#' incompatible version of jlbind, or with other options. If a library is
#' already loaded, restart R to use the new one.
#'
#' With `method = "download"`, packages that offer a pre-built library get it
#' downloaded instead, so you don't need Julia; see
#' `vignette("using-clients", "jlbind")`.
#'
#' The library is compiled for this computer's CPU, and may crash R on another;
#' jlbind warns before loading it on another CPU model. If one R library is used
#' from computers with different CPUs, as on a cluster, use
#' `cpu_target = "generic"`, or name CPUs they all support, such as
#' `"x86-64-v3"`. See `vignette("build-options", "jlbind")` for how these
#' compare.
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
#' @param bundle If `TRUE`, copy the Julia runtime next to the shared library,
#'   so that it runs without Julia installed. This makes the library much
#'   larger, and is only useful for giving a library to people without Julia,
#'   who set `JLBIND_LIBRARY` to it. They also need a `cpu_target` other than
#'   `"native"`. See `vignette("build-options", "jlbind")`.
#' @param private Names of packages among `packages` to give a library of
#'   their own, with a private Julia runtime. On Windows, that needs a JuliaC
#'   not yet released, named by `JLBIND_JULIAC`; see
#'   `vignette("libraries", "jlbind")`. By default, the packages given one by
#'   an earlier build. `character()` puts every package in the shared library.
#' @param method `"build"` compiles the libraries with Julia. `"download"`
#'   downloads the pre-built libraries that packages offer, checked against
#'   the SHA-256 hashes the packages list, and takes no build options.
#'
#' @return The path to the shared library (invisibly), or `NULL` if there was
#'   nothing to build. With every package private, the path to the first
#'   private library.
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
#'
#' # pkgB in a library of its own, as its Julia dependencies conflict with
#' # those of pkgA
#' install_library(private = "pkgB")
#'
#' # The pre-built library of pkgA, without Julia
#' install_library("pkgA", method = "download")
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
  bundle = FALSE,
  private = NULL,
  method = c("build", "download")
) {
  method <- match.arg(method)
  if (method == "download") {
    build_args <- c(
      "julia",
      "versions",
      "develop",
      "cpu_target",
      "julia_args",
      "bundle",
      "private"
    )
    given <- build_args[c(
      !missing(julia),
      !missing(versions),
      !missing(develop),
      !missing(cpu_target),
      !missing(julia_args),
      !missing(bundle),
      !missing(private)
    )]
    if (length(given)) {
      stop(
        "`method = \"download\"` installs pre-built libraries, which take ",
        "none of the build options: ",
        paste0("`", given, "`", collapse = ", "),
        ".",
        call. = FALSE
      )
    }
    return(.install_download(packages, ask, force))
  }
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
    downloaded <- character()
  } else {
    # Pre-built private libraries are kept unless a package is named.
    downloaded <- .downloaded_packages(clients$package)
    if (length(downloaded)) {
      message(
        "Keeping the pre-built ",
        if (length(downloaded) > 1L) "libraries" else "library",
        " of ",
        paste(downloaded, collapse = ", "),
        "; name ",
        if (length(downloaded) > 1L) "them" else "it",
        " in `packages` to build ",
        if (length(downloaded) > 1L) "them" else "it",
        " instead."
      )
      clients <- clients[!clients$package %in% downloaded, , drop = FALSE]
    }
  }
  if (nrow(clients) == 0L) {
    if (!length(downloaded)) {
      message("No installed package uses jlbind, so there is nothing to build.")
    }
    .bind_requested()
    return(invisible(NULL))
  }
  private <- .check_private(private, clients$package)
  julia <- .find_julia(julia)
  julia_version <- .julia_version(julia)

  # The libraries to build: the shared one, unless every package is private,
  # and one for each private package.
  shared <- clients[!clients$package %in% private, , drop = FALSE]
  targets <- c(
    if (nrow(shared)) {
      list(list(clients = shared, dir = .library_dir(), salt = NULL))
    },
    lapply(private, function(pkg) {
      list(
        clients = clients[clients$package == pkg, , drop = FALSE],
        dir = .private_dir(pkg),
        salt = .salt(pkg)
      )
    })
  )
  for (i in seq_along(targets)) {
    t <- targets[[i]]
    targets[[i]]$build <- force ||
      versions != "manifest" ||
      length(develop) > 0L ||
      !.up_to_date(
        t$dir,
        t$clients,
        julia_version,
        cpu_target,
        julia_args,
        bundle || !is.null(t$salt),
        if (is.null(t$salt)) "" else t$salt
      )
  }
  path <- file.path(targets[[1L]]$dir, .library_file())
  todo <- Filter(function(t) t$build, targets)
  if (!length(todo)) {
    .set_private(clients$package, private)
    message(
      "The compiled Julia ",
      if (length(targets) > 1L) "libraries are" else "library is",
      " up to date (",
      paste(
        vapply(targets, function(t) file.path(t$dir, .library_file()), ""),
        collapse = ", "
      ),
      "); use `force = TRUE` to rebuild ",
      if (length(targets) > 1L) "them." else "it."
    )
    .bind_requested()
    return(invisible(path))
  }

  if (isTRUE(ask)) {
    what <- vapply(
      todo,
      function(t) {
        paste0(
          paste(t$clients$package, collapse = ", "),
          if (!is.null(t$salt)) " (in a library of its own)"
        )
      },
      ""
    )
    choice <- utils::menu(
      c("Yes", "No"),
      title = paste0(
        "Compile the Julia code of ",
        paste(what, collapse = "; "),
        " with ",
        julia,
        "? Julia downloads their Julia dependencies into its package depot, ",
        "and compiling can take a few minutes. The ",
        if (length(todo) > 1L) "libraries are" else "library is",
        " written to ",
        tools::R_user_dir("jlbind", "cache"),
        "."
      )
    )
    if (choice != 1L) {
      message("Cancelled.")
      return(invisible(NULL))
    }
  }

  # One build at a time: each can take much of the computer's memory.
  for (t in todo) {
    .install_build(
      t$clients,
      t$dir,
      julia,
      versions,
      develop,
      cpu_target,
      julia_args,
      bundle && is.null(t$salt),
      t$salt
    )
  }
  .set_private(clients$package, private)

  noun <- if (length(todo) > 1L) "libraries" else "library"
  if (length(.loaded_libraries())) {
    message(
      "Built the compiled Julia ",
      noun,
      ". Restart R to use ",
      if (length(todo) > 1L) "them" else "it",
      " in place of the libraries loaded in this session."
    )
  } else {
    message("Built the compiled Julia ", noun, ".")
  }
  .bind_requested()
  invisible(path)
}

# Builds `clients` into `dir` in place of the library there, for
# install_library(); the other arguments are those of .build().
.install_build <- function(
  clients,
  dir,
  julia,
  versions,
  develop,
  cpu_target,
  julia_args,
  bundle,
  salt
) {
  # Built next to its final place, so it is moved in with a rename, and only
  # once the build has succeeded.
  root <- dirname(dir)
  dir.create(root, recursive = TRUE, showWarnings = FALSE)
  out <- tempfile("build-", tmpdir = root)
  on.exit(unlink(out, recursive = TRUE), add = TRUE)
  .build(
    clients,
    out,
    julia,
    versions,
    develop,
    cpu_target,
    julia_args,
    bundle,
    salt
  )

  .replace_dir(out, dir)
}

# Moves the library directory `out` to `dir`, in place of the library there.
.replace_dir <- function(out, dir) {
  root <- dirname(dir)
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
  invisible(dir)
}

# The `private` packages of install_library(), out of `packages`: by default,
# those recorded as private by an earlier build.
.check_private <- function(private, packages) {
  if (is.null(private)) {
    return(.private_packages(packages))
  }
  if (!is.character(private) || anyNA(private)) {
    stop("`private` must be a character vector.", call. = FALSE)
  }
  missing <- setdiff(private, packages)
  if (length(missing)) {
    stop(
      "`private` names packages that are not being built: ",
      paste(missing, collapse = ", "),
      ".",
      call. = FALSE
    )
  }
  if (length(private)) {
    .windows_private_message()
  }
  unique(private)
}

# Which of `packages` are private. install_library() records them in a file
# under the config directory, so the choice outlives the libraries, which are
# in the cache.
.private_packages <- function(packages) {
  packages[packages %in% .read_private()]
}

# Which of `packages` have a private library built by install_library().
.built_private <- function(packages) {
  packages[file.exists(file.path(.private_dir(packages), .library_file()))]
}

# Records `private` as the private ones among `packages`, which were just
# built, keeping the record of the others, and removes the private libraries
# of those put back into the shared library.
.set_private <- function(packages, private) {
  .write_private(c(setdiff(.read_private(), packages), private))
  .remove_private(setdiff(.built_private(packages), private))
}

.private_file <- function() {
  file.path(tools::R_user_dir("jlbind", "config"), "private-packages")
}

.read_private <- function() {
  file <- .private_file()
  if (file.exists(file)) readLines(file, warn = FALSE) else character()
}

.write_private <- function(packages) {
  file <- .private_file()
  if (!length(packages)) {
    unlink(file)
    return(invisible(NULL))
  }
  dir.create(dirname(file), recursive = TRUE, showWarnings = FALSE)
  writeLines(sort(unique(packages), method = "radix"), file)
  invisible(NULL)
}

# Removes the private libraries of `packages`, which are built into the shared
# library now. One loaded in this session is left for the next build, as it
# cannot be removed on Windows; it is not used once the shared library has the
# package, since a client binds to the library .library_path() gives.
.remove_private <- function(packages) {
  for (pkg in packages) {
    dir <- .private_dir(pkg)
    old <- tempfile("old-", tmpdir = dirname(dir))
    if (file.rename(dir, old)) {
      unlink(old, recursive = TRUE)
    }
  }
  invisible(NULL)
}

# Where install_library() builds the private libraries.
.private_root <- function() {
  file.path(tools::R_user_dir("jlbind", "cache"), "private")
}

# Where install_library() builds the private library of `pkg`.
.private_dir <- function(pkg) {
  file.path(.private_root(), pkg)
}

# The salt of the private Julia runtime of a library built from `packages`:
# JuliaC renames the runtime's symbols with it, so libraries in one process
# need different ones. It must match `[A-Za-z_][A-Za-z0-9_]*` and have at most
# 8 characters.
.salt <- function(packages) {
  record <- tempfile()
  on.exit(unlink(record))
  writeLines(sort(unique(packages), method = "radix"), record)
  paste0("jl", substr(unname(tools::md5sum(record)), 1L, 6L))
}

#' Remove the Julia library
#'
#' Deletes the libraries built by [install_library()], with everything else
#' jlbind stores in `tools::R_user_dir("jlbind", "cache")`, and the record of
#' which packages have a private library. Packages that use jlbind can't call
#' their Julia code until you run [install_library()] again.
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
    .write_private(character())
    message("There is no compiled Julia library to remove.")
    return(invisible(FALSE))
  }
  # The libraries removed: the shared one and the private ones.
  removed <- file.path(
    c(dir, .private_dir(list.files(.private_root()))),
    .library_file()
  )
  # The shared library counts as loaded once it was looked for.
  loaded <- any(
    c(.state$path, vapply(.loaded_libraries(), function(lib) lib$path, "")) %in%
      removed
  )
  # A loaded DLL cannot be deleted on Windows, and deleting the rest would
  # leave a library that cannot be used.
  if (loaded && .Platform$OS.type == "windows") {
    stop(
      "A library is loaded in this R session. Restart R and run ",
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
  .write_private(character())
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
#' @param private If `TRUE`, give the library a private Julia runtime, as
#'   `private` does in [install_library()]. The library then loads alongside
#'   the shared one, and the packages built into it bind to it.
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
  bundle = FALSE,
  private = FALSE
) {
  versions <- match.arg(versions)
  cpu_target <- .cpu_target(cpu_target)
  julia_args <- .julia_args(julia_args)
  .check_bundle(bundle)
  if (!isTRUE(private) && !isFALSE(private)) {
    stop("`private` must be TRUE or FALSE.", call. = FALSE)
  }
  if (private) {
    .windows_private_message()
  }
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
  .build(
    clients,
    out,
    julia,
    versions,
    develop,
    cpu_target,
    julia_args,
    bundle,
    if (private) .salt(clients$package)
  )
  invisible(file.path(normalizePath(out), .library_file()))
}

# Released JuliaC gives a library a private Julia runtime on Linux and macOS
# only; on Windows, that needs JuliaC.jl#151 (JLBIND_JULIAC).
.windows_private_message <- function(windows = .Platform$OS.type == "windows") {
  if (windows && !nzchar(.juliac())) {
    message(
      "Released JuliaC can't give a library a private Julia runtime on ",
      "Windows yet, so the library won't load alongside others. To build ",
      "one, set JLBIND_JULIAC to a JuliaC with Windows support, such as ",
      "that of https://github.com/JuliaLang/JuliaC.jl/pull/151:\n",
      "  Sys.setenv(JLBIND_JULIAC = \"",
      .juliac_windows,
      "\")"
    )
  }
  invisible(NULL)
}

# The JuliaC to build with, from JLBIND_JULIAC: a local directory, or a git
# URL with an optional `#<rev>`; "" for its registered release.
.juliac <- function() {
  trimws(Sys.getenv("JLBIND_JULIAC", unset = ""))
}

# JuliaC with Windows support for private runtimes (JuliaC.jl#151).
.juliac_windows <- "https://github.com/asinghvi17/JuliaC.jl#as/windows-privatize"

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
# runtime checks clients against. With a `salt` (.salt()), the library is a
# bundle with a private Julia runtime.
.build <- function(
  clients,
  out,
  julia,
  versions = "manifest",
  develop = NULL,
  cpu_target = "native",
  julia_args = character(),
  bundle = FALSE,
  salt = NULL
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
  if (bundle && is.null(salt) && .native_only(cpu_target)) {
    message(
      "Building a bundle for CPU target \"",
      cpu_target,
      "\", which may crash R on CPUs other than this one. To give it to ",
      "others, use another `cpu_target`, such as \"generic\"."
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
      if (!is.null(salt)) paste0("--privatize=", salt),
      if (nzchar(.juliac())) shQuote(paste0("--juliac=", .juliac())),
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
      Bundle = bundle || !is.null(salt),
      Private = if (is.null(salt)) "" else salt,
      ABI = .library_abi,
      JuliaC = .juliac()
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
  file.path(tools::R_user_dir("jlbind", "cache"), "library")
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

# Why a library built as `build` (.read_build()) can't be used by this
# jlbind, as "built for ...", or NULL if it can.
.abi_mismatch <- function(build) {
  if (identical(unname(build$ABI), as.character(.library_abi))) {
    return(NULL)
  }
  paste0(
    "built for ",
    if (!nzchar(build$ABI)) {
      "an older version"
    } else {
      paste0("version ", build$ABI)
    },
    " of jlbind's interface to libraries, not ",
    .library_abi,
    ", the version of this jlbind"
  )
}

# How the library in `dir` was built (a list with jlbind, Julia, Built, Trim,
# Develop, CpuTarget, CPU, JuliaArgs, Bundle, Private, ABI and JuliaC, and for
# a pre-built library install_library(method = "download") installed, Download
# and SHA256; "" where not recorded), or NULL if it records nothing.
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
    "Bundle",
    "Private",
    "ABI",
    "JuliaC",
    "Download",
    "SHA256"
  )
  build <- read.dcf(file, fields = fields)[1L, ]
  build[is.na(build)] <- ""
  as.list(build)
}

# Was the library in `dir` built for this jlbind's interface and Julia version
# `julia`, for `cpu_target`, with `julia_args`, as a bundle or not (`bundle`),
# with the private runtime salt `private` ("" for none), from exactly these
# versions of these clients, with the same binding package files (counting
# the clients it left out), and with no local checkouts?
.up_to_date <- function(
  dir,
  clients,
  julia,
  cpu_target = NA,
  julia_args = NULL,
  bundle = NA,
  private = NA
) {
  !length(.stale_reasons(
    dir,
    clients,
    julia,
    cpu_target,
    julia_args,
    bundle,
    private
  ))
}

# Why the library in `dir` is not what install_library() would build from
# `clients` with Julia version `julia` for `cpu_target` with `julia_args`, as a
# bundle or not (`bundle`), with private runtime salt `private` (each skipped
# if NA or NULL): a character vector, empty if it is up to date.
.stale_reasons <- function(
  dir,
  clients,
  julia,
  cpu_target = NA,
  julia_args = NULL,
  bundle = NA,
  private = NA
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
    .build_reasons(build, julia, cpu_target, julia_args, bundle, private),
    paste0(status$package, ": ", status$status)[
      !status$status %in% c("ok", "left out")
    ]
  )
}

# Why a library built as `build` (.read_build()) is out of date regardless of
# its clients, for Julia version `julia`, `cpu_target`, `julia_args`,
# `bundle` and private runtime salt `private` (each skipped if NA or NULL). A
# bundle doesn't use the installed Julia, so another version of it is no
# reason.
.build_reasons <- function(
  build,
  julia,
  cpu_target = NA,
  julia_args = NULL,
  bundle = NA,
  private = NA
) {
  bundled <- identical(build$Bundle, "TRUE")
  julia_args <- if (!is.null(julia_args)) paste(julia_args, collapse = " ")
  c(
    .abi_mismatch(build),
    if (
      !bundled && !is.na(julia) && !identical(build$Julia, as.character(julia))
    ) {
      paste0("built with Julia ", build$Julia, ", not ", julia)
    },
    if (!is.na(bundle) && !identical(bundled, bundle)) {
      if (bundled) "built as a bundle" else "not built as a bundle"
    },
    if (!is.na(private) && !identical(build$Private, private)) {
      if (nzchar(private)) {
        "built without its own Julia runtime"
      } else {
        "built with its own Julia runtime"
      }
    },
    if (!is.na(cpu_target) && !identical(build$CpuTarget, cpu_target)) {
      paste0(
        "built for CPU target \"",
        build$CpuTarget,
        "\", not \"",
        cpu_target,
        "\""
      )
    },
    .cpu_mismatch(build),
    if (!is.null(julia_args) && !identical(build$JuliaArgs, julia_args)) {
      paste0(
        "built with Julia arguments \"",
        build$JuliaArgs,
        "\", not \"",
        julia_args,
        "\""
      )
    },
    if (nzchar(build$Develop)) {
      "built with local checkouts (`develop`)"
    },
    # Only a JuliaC asked for with JLBIND_JULIAC is a reason, so a library
    # built with one (such as a private library on Windows) is kept in
    # sessions without it. A pre-built library is whatever its authors built
    # it with.
    if (
      !.is_downloaded(build) &&
        nzchar(.juliac()) &&
        !identical(unname(build$JuliaC), .juliac())
    ) {
      paste0(
        "built with JuliaC ",
        if (nzchar(build$JuliaC)) build$JuliaC else "0.3",
        ", not ",
        .juliac(),
        " (JLBIND_JULIAC)"
      )
    }
  )
}

# Whether code compiled for the CPU target `target` runs only on the CPU
# model that compiled it: its first target, which the others fall back to, is
# "native". "generic;native,clone_all" runs on any CPU.
.native_only <- function(target) {
  first <- strsplit(target, ";", fixed = TRUE)[[1L]][1L]
  identical(trimws(strsplit(first, ",", fixed = TRUE)[[1L]][1L]), "native")
}

# Why a library built as `build` (.read_build()) may crash on this computer:
# it was compiled for the native CPU of a computer with another CPU model.
# NULL if not, or if either CPU is unknown.
.cpu_mismatch <- function(build, cpu = .cpu_model()) {
  if (
    !.native_only(build$CpuTarget) ||
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
