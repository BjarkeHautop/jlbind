#' Set up a package to use jlbind
#'
#' Adds what a package needs to call Julia code through jlbind.
#'
#' * A Julia binding package in `inst/<dir>`, with one example function,
#'   `hello()`. An existing binding package is left alone.
#' * `R/jlbind-wrappers.R` (written by [update_entrypoints()]), with an R
#'   function for each Julia function declared with `@rcall`.
#' * `R/jlbind.R`, with an `.onLoad()` that calls [bind_client()]. If the
#'   package already has an `.onLoad()`, add `jlbind::bind_client(pkgname)` to
#'   it yourself.
#' * The `Config/jlbind` and `Imports: jlbind` fields in `DESCRIPTION`.
#' * `.jlbind/`, where [build_library()] writes a library for development, in
#'   `.Rbuildignore` and `.gitignore`.
#'
#' @param path Path to the package sources.
#' @param module Name of the Julia binding package. Defaults to the package name
#'   followed by `Bindings`. It must be unique across all packages that use
#'   jlbind, since they're all compiled into one library.
#' @param dir Directory under `inst/` for the binding package.
#'
#' @return `path`, invisibly.
#' @export
#' @examples
#' # A new package in a temporary directory
#' pkg <- file.path(tempdir(), "mypkg")
#' dir.create(pkg)
#' writeLines(
#'   c(
#'     "Package: mypkg",
#'     "Title: Demo",
#'     "Version: 0.1.0",
#'     "Description: Demo.",
#'     "License: MIT"
#'   ),
#'   file.path(pkg, "DESCRIPTION")
#' )
#'
#' use_jlbind(pkg)
#' list.files(pkg, recursive = TRUE)
#'
#' # The Julia binding package, with its example entrypoint
#' writeLines(readLines(file.path(pkg, "inst/julia/src/mypkgBindings.jl")))
use_jlbind <- function(path = ".", module = NULL, dir = "julia") {
  desc_file <- file.path(path, "DESCRIPTION")
  if (!file.exists(desc_file)) {
    stop("No package found in ", path, ".", call. = FALSE)
  }
  pkg <- read.dcf(desc_file, fields = "Package")[[1L]]
  binding <- file.path(path, "inst", dir)
  if (file.exists(file.path(binding, "Project.toml"))) {
    module <- .binding_name(binding)
    message("Using the binding package ", module, " in ", binding, ".")
  } else {
    if (is.null(module)) {
      module <- paste0(gsub("[^A-Za-z0-9]", "", pkg), "Bindings")
    }
    if (!grepl("^[A-Za-z][A-Za-z0-9_]*$", module)) {
      stop("`module` must be a valid Julia package name.", call. = FALSE)
    }
    vars <- list(
      package = pkg,
      module = module,
      uuid = .uuid3(module),
      jlbind_rev = .jlbind_rev()
    )
    dir.create(
      file.path(binding, "src"),
      recursive = TRUE,
      showWarnings = FALSE
    )
    .write_template("Project.toml", file.path(binding, "Project.toml"), vars)
    .write_template(
      "module.jl",
      file.path(binding, "src", paste0(module, ".jl")),
      vars
    )
    message("Created the binding package ", module, " in ", binding, ".")
  }

  .set_description(desc_file, dir)
  update_entrypoints(path)
  .add_line(file.path(path, ".Rbuildignore"), "^\\.jlbind$")
  .add_line(file.path(path, ".gitignore"), ".jlbind/")

  r_dir <- file.path(path, "R")
  dir.create(r_dir, showWarnings = FALSE)
  r_files <- setdiff(
    list.files(r_dir, "\\.[Rr]$", full.names = TRUE),
    file.path(r_dir, "jlbind.R")
  )
  has_onload <- any(vapply(
    r_files,
    function(f) {
      any(grepl("^\\s*\\.onLoad\\s*(<-|=)", readLines(f, warn = FALSE)))
    },
    TRUE
  ))
  r_file <- file.path(r_dir, "jlbind.R")
  if (has_onload) {
    message(
      "The package has an .onLoad() already: call ",
      "`jlbind::bind_client(pkgname)` from it."
    )
  }
  if (!has_onload) {
    writeLines(.template("jlbind.R"), r_file)
  }
  invisible(path)
}

#' Check a package with its Julia code on GitHub Actions
#'
#' Writes a GitHub Actions workflow that checks the package with and without
#' Julia. With Julia, it runs `R CMD check` on Linux, Windows and macOS after
#' compiling the package's Julia code with [build_library()], so tests and
#' examples that need the library run. Without Julia, it checks the package
#' once on Linux, as CRAN does, where those tests and examples must be skipped.
#' The workflow is written to `.github/workflows/R-CMD-check.yaml`.
#'
#' The workflow replaces the standard one written by
#' `usethis::use_github_action("check-standard")`, which has the same name.
#'
#' @param path Path to the package sources.
#' @param overwrite If `TRUE`, replace an existing
#'   `.github/workflows/R-CMD-check.yaml`.
#'
#' @return The path to the workflow, invisibly.
#' @export
#' @examples
#' # A package in a temporary directory
#' pkg <- tempfile("mypkg")
#' dir.create(pkg)
#' writeLines(c("Package: mypkg", "Version: 0.1.0"), file.path(pkg, "DESCRIPTION"))
#'
#' file <- use_jlbind_ci(pkg)
#' writeLines(readLines(file))
use_jlbind_ci <- function(path = ".", overwrite = FALSE) {
  if (!file.exists(file.path(path, "DESCRIPTION"))) {
    stop("No package found in ", path, ".", call. = FALSE)
  }
  dir <- file.path(path, ".github", "workflows")
  file <- file.path(dir, "R-CMD-check.yaml")
  if (file.exists(file) && !overwrite) {
    stop(
      file,
      " exists already; use `overwrite = TRUE` to replace it.",
      call. = FALSE
    )
  }
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  writeLines(.template("R-CMD-check.yaml"), file)
  .add_line(file.path(path, ".Rbuildignore"), "^\\.github$")
  message("Wrote ", file, ".")
  invisible(file)
}

#' Update the list of Julia functions R can call
#'
#' Finds the `@rcall` declarations in the package's Julia binding package and
#' writes `R/jlbind-wrappers.R`, with an R function for each that calls the
#' compiled Julia function. Run this whenever you add or remove an `@rcall`, or
#' change its arguments.
#' `@rcall shift(x::Vector{Float64}, by::Float64 = 0.0)::Float64` becomes
#' `shift <- function(x, by = 0.0) .External(.jlbind$.call, .jlbind$shift, x,
#' by)`, where [bind_client()] puts the compiled function into `.jlbind`.
#'
#' Defaults must be literal numbers, strings, `true`, `false` or `nothing`
#' (`NULL`). A function returning `Nothing` returns invisibly. To export or
#' document a function, write roxygen comments (`#'`) directly above its
#' `@rcall`: they're copied above the R function, so roxygen2 sees its signature.
#' To add R code around a call, declare the Julia function with a `jl_` prefix
#' and write the R function yourself, calling the generated `jl_` function.
#'
#' @param path Path to the package sources.
#'
#' @return Invisibly, a data frame of the entrypoints with the columns `name`,
#'   `nargs`, and the `formals`, `args`, `invisible` (whether it returns
#'   invisibly) and `roxygen` (the comments above its `@rcall`) of their R
#'   wrappers.
#' @export
#' @examples
#' # A package set up with use_jlbind() in a temporary directory
#' pkg <- file.path(tempdir(), "addpkg")
#' dir.create(pkg)
#' writeLines(
#'   c(
#'     "Package: addpkg",
#'     "Title: Demo",
#'     "Version: 0.1.0",
#'     "Description: Demo.",
#'     "License: MIT"
#'   ),
#'   file.path(pkg, "DESCRIPTION")
#' )
#' use_jlbind(pkg)
#'
#' # Add an entrypoint to the binding package, before its closing `end`
#' file <- file.path(pkg, "inst/julia/src/addpkgBindings.jl")
#' code <- readLines(file)
#' last <- max(which(code == "end"))
#' code <- append(
#'   code,
#'   c(
#'     "add(x::Float64, y::Float64) = x + y",
#'     "@rcall add(x::Float64, y::Float64)::Float64",
#'     ""
#'   ),
#'   after = last - 1L
#' )
#' writeLines(code, file)
#'
#' update_entrypoints(pkg)
#' writeLines(readLines(file.path(pkg, "R", "jlbind-wrappers.R")))
update_entrypoints <- function(path = ".") {
  info <- .client_info(path)
  files <- sort(list.files(
    file.path(info$path, "src"),
    "\\.jl$",
    recursive = TRUE,
    full.names = TRUE
  ))
  entries <- do.call(
    rbind,
    lapply(files, function(f) {
      .find_rcalls(paste(readLines(f, warn = FALSE), collapse = "\n"), f)
    })
  )
  if (is.null(entries)) {
    entries <- data.frame(
      name = character(),
      nargs = integer(),
      formals = character(),
      args = character(),
      invisible = logical(),
      roxygen = character()
    )
  }
  dup <- entries$name[duplicated(entries$name)]
  if (length(dup)) {
    stop("More than one `@rcall ", dup[[1L]], "`.", call. = FALSE)
  }
  bad <- entries$name[!grepl("^[A-Za-z_][A-Za-z0-9_]*$", entries$name)]
  if (length(bad)) {
    stop(
      "`@rcall ",
      bad[[1L]],
      "`: an entrypoint's name must be a valid C identifier.",
      call. = FALSE
    )
  }
  .write_if_changed(
    .wrappers(entries, info$module),
    file.path(path, "R", "jlbind-wrappers.R"),
    paste0(" (", nrow(entries), " entrypoints)")
  )
  invisible(entries)
}

# R/jlbind-wrappers.R for the entrypoints of the binding package `module`:
# what bind_client() needs to bind them (.client_vars), and the R wrapper of
# each, `f <- function(x, by = NULL) .External(.jlbind$.call, .jlbind$f, x,
# by)`, below the roxygen comments of its declaration.
.wrappers <- function(entries, module) {
  header <- c(
    "# Generated by jlbind::update_entrypoints(): do not edit by hand",
    "",
    "# The entrypoints of the Julia binding package, which",
    "# jlbind::bind_client() looks up in the compiled library and puts into",
    "# `.jlbind` for the functions below.",
    paste0(".jlbind_module <- \"", module, "\""),
    if (nrow(entries)) {
      c(
        ".jlbind_entries <- c(",
        paste0("  \"", entries$name, "\"", c(rep(",", nrow(entries) - 1L), "")),
        ")"
      )
    } else {
      ".jlbind_entries <- character()"
    },
    ".jlbind <- new.env(parent = emptyenv())"
  )
  if (nrow(entries) == 0L) {
    return(header)
  }
  call_args <- ifelse(
    nzchar(entries$args),
    paste0(", ", entries$args),
    ""
  )
  call <- paste0(
    ".External(.jlbind$.call, .jlbind$",
    entries$name,
    call_args,
    ")"
  )
  call <- ifelse(entries$invisible, paste0("invisible(", call, ")"), call)
  head <- paste0(entries$name, " <- function(", entries$formals, ")")
  one_line <- paste(head, call)
  code <- ifelse(
    nchar(one_line) <= 80L,
    one_line,
    paste0(head, " {\n  ", call, "\n}")
  )
  has_roxygen <- nzchar(entries$roxygen)
  code[has_roxygen] <- paste0(
    "\n",
    entries$roxygen[has_roxygen],
    "\n",
    code[has_roxygen]
  )
  c(header, "", unlist(strsplit(code, "\n", fixed = TRUE)))
}

.write_if_changed <- function(lines, file, note = "") {
  old <- if (file.exists(file)) readLines(file, warn = FALSE)
  if (!identical(old, lines)) {
    dir.create(dirname(file), showWarnings = FALSE)
    writeLines(lines, file)
    message("Wrote ", file, note, ".")
  }
}

# The `@rcall` declarations in Julia source `src`: a data frame of each
# entrypoint's name, number of arguments, the formals and arguments of its
# R wrapper (e.g. "x, by = NULL" and "x, by"), whether the wrapper returns
# invisibly (the return type is `Nothing`), and the roxygen comments above the
# declaration.
.find_rcalls <- function(src, file = "<text>") {
  code <- .julia_code(src)
  pattern <- "@rcall[ \t]+([A-Za-z_][A-Za-z0-9_!]*)[ \t]*\\("
  m <- gregexpr(pattern, code, perl = TRUE)[[1L]]
  if (m[[1L]] == -1L) {
    return(NULL)
  }
  starts <- attr(m, "capture.start")[, 1L]
  lens <- attr(m, "capture.length")[, 1L]
  names <- substring(code, starts, starts + lens - 1L)
  open <- m + attr(m, "match.length") - 1L
  ch <- strsplit(code, "")[[1L]]
  orig <- strsplit(src, "")[[1L]]
  segments <- lapply(open, function(i) .rcall_args(ch, i, file))
  args <- lapply(seq_along(open), function(k) {
    lapply(segments[[k]], function(s) {
      .rcall_arg(ch[s], orig[s], paste0("@rcall ", names[[k]], " in ", file))
    })
  })
  # What follows the closing parenthesis: the return type.
  rest <- substring(code, vapply(segments, attr, 1L, "end") + 1L)
  returns_nothing <- grepl(
    "^\\s*::\\s*Nothing(?![A-Za-z0-9_!])",
    rest,
    perl = TRUE
  )
  join <- function(a, f) {
    vapply(a, function(x) paste(vapply(x, f, ""), collapse = ", "), "")
  }
  lines <- strsplit(src, "\n", fixed = TRUE)[[1L]]
  line_starts <- cumsum(c(1L, nchar(lines)[-length(lines)] + 1L))
  data.frame(
    name = names,
    nargs = lengths(args),
    formals = join(args, function(x) {
      if (is.na(x$default)) x$name else paste(x$name, "=", x$default)
    }),
    args = join(args, function(x) x$name),
    invisible = returns_nothing,
    roxygen = vapply(
      findInterval(as.integer(m), line_starts),
      function(line) .rcall_roxygen(lines, line),
      ""
    )
  )
}

# The roxygen comments directly above line `line` of `lines`, without their
# indentation, as one string ("" if there are none).
.rcall_roxygen <- function(lines, line) {
  first <- line
  while (first > 1L && grepl("^\\s*#'", lines[[first - 1L]])) {
    first <- first - 1L
  }
  if (first == line) {
    return("")
  }
  paste(trimws(lines[seq.int(first, line - 1L)]), collapse = "\n")
}

# The positions of each argument in the call whose opening parenthesis is
# `ch[i]`: a list of integer vectors, without the separating commas, with the
# position of the closing parenthesis as attribute `end`.
.rcall_args <- function(ch, i, file) {
  depth <- 0L
  out <- list()
  start <- i + 1L
  for (j in seq.int(i, length(ch))) {
    c <- ch[[j]]
    if (c %in% c("(", "[", "{")) {
      depth <- depth + 1L
    } else if (c %in% c(")", "]", "}")) {
      depth <- depth - 1L
    } else if (depth == 1L && c == ";") {
      stop(
        "@rcall in ",
        file,
        ": keyword arguments are not supported.",
        call. = FALSE
      )
    }
    if (depth == 0L || (depth == 1L && c == ",")) {
      seg <- seq.int(start, length.out = j - start)
      # A trailing comma does not start another argument.
      if (!all(grepl("\\s", ch[seg]))) {
        out[[length(out) + 1L]] <- seg
      }
      if (depth == 0L) {
        return(structure(out, end = j))
      }
      start <- j + 1L
    }
  }
  stop("@rcall in ", file, ": unbalanced parentheses.", call. = FALSE)
}

# One `@rcall` argument, `name::Type` or `name::Type = default`, given as its
# characters with strings blanked (`code`) and as written (`orig`): a list of
# its R name and default (an R literal, or NA for none).
.rcall_arg <- function(code, orig, where) {
  depth <- cumsum(code %in% c("(", "[", "{")) -
    cumsum(code %in% c(")", "]", "}"))
  prev <- c("", code[-length(code)])
  nxt <- c(code[-1L], "")
  eq <- which(
    code == "=" &
      depth == 0L &
      !prev %in% c("=", "<", ">", "!") &
      !nxt %in% c("=", ">")
  )
  decl <- trimws(paste(
    orig[seq_len(if (length(eq)) eq[[1L]] - 1L else length(orig))],
    collapse = ""
  ))
  name <- regmatches(decl, regexec("^([^:[:space:]]+)\\s*::", decl))[[1L]][2L]
  if (is.na(name)) {
    stop(
      where,
      ": every argument needs a type, as in `x::Float64`.",
      call. = FALSE
    )
  }
  if (make.names(name) != name) {
    stop(where, ": `", name, "` is not a valid R argument name.", call. = FALSE)
  }
  default <- NA_character_
  if (length(eq)) {
    default <- .r_default(
      trimws(paste(orig[-seq_len(eq[[1L]])], collapse = "")),
      paste0(where, ", argument `", name, "`")
    )
  }
  list(name = name, default = default)
}

# The R literal for the Julia default `x`: a number, string, `true`, `false`
# or `nothing`, the defaults `@rcall` accepts.
.r_default <- function(x, where) {
  number <- "^[+-]?([0-9]+\\.?[0-9]*|\\.[0-9]+)([eE][+-]?[0-9]+)?$"
  string <- "^\"([^\"\\\\$]|\\\\[\\\\\"nt])*\"$"
  if (x == "nothing") {
    "NULL"
  } else if (x == "true") {
    "TRUE"
  } else if (x == "false") {
    "FALSE"
  } else if (grepl(number, x) || grepl(string, x)) {
    x
  } else {
    stop(
      where,
      ": a default must be a literal number, string, `true`, `false` or ",
      "`nothing`.",
      call. = FALSE
    )
  }
}

# Julia source with comments, strings and character literals blanked out
# (newlines kept), so only code is left to search.
.julia_code <- function(src) {
  ch <- strsplit(src, "")[[1L]]
  n <- length(ch)
  blank <- function(from, to) {
    k <- seq.int(from, min(to, n))
    ch[k[ch[k] != "\n"]] <<- " "
  }
  at <- function(j, s) {
    k <- j + seq_len(nchar(s)) - 1L
    all(k <= n) && identical(paste(ch[k], collapse = ""), s)
  }
  i <- 1L
  while (i <= n) {
    c <- ch[[i]]
    if (c == "#" && at(i, "#=")) {
      depth <- 1L
      j <- i + 2L
      while (j <= n && depth > 0L) {
        if (at(j, "#=")) {
          depth <- depth + 1L
          j <- j + 2L
        } else if (at(j, "=#")) {
          depth <- depth - 1L
          j <- j + 2L
        } else {
          j <- j + 1L
        }
      }
    } else if (c == "#") {
      j <- i
      while (j <= n && ch[[j]] != "\n") {
        j <- j + 1L
      }
    } else if (c == "\"") {
      delim <- if (at(i, "\"\"\"")) "\"\"\"" else "\""
      j <- i + nchar(delim)
      while (j <= n && !at(j, delim)) {
        j <- j + if (ch[[j]] == "\\") 2L else 1L
      }
      j <- j + nchar(delim)
    } else if (
      c == "'" && (i == 1L || !grepl("[]A-Za-z0-9_)}'.!]", ch[[i - 1L]]))
    ) {
      # A character literal, not the adjoint operator.
      j <- i + 1L
      while (j <= n && ch[[j]] != "'") {
        j <- j + if (ch[[j]] == "\\") 2L else 1L
      }
      j <- j + 1L
    } else {
      i <- i + 1L
      next
    }
    blank(i, j - 1L)
    i <- j
  }
  paste(ch, collapse = "")
}

# Adds the jlbind fields to a package's DESCRIPTION.
.set_description <- function(file, dir) {
  fields <- colnames(read.dcf(file))
  desc <- read.dcf(file, keep.white = fields)
  changed <- FALSE
  set <- function(field, value) {
    if (!field %in% colnames(desc)) {
      desc <<- cbind(desc, matrix(value, dimnames = list(NULL, field)))
    } else if (!identical(unname(desc[, field]), value)) {
      desc[, field] <<- value
    } else {
      return()
    }
    changed <<- TRUE
  }
  set(.field, dir)
  imports <- if ("Imports" %in% fields) desc[, "Imports"] else NA
  deps <- if (is.na(imports)) {
    character()
  } else {
    trimws(strsplit(imports, ",")[[1L]])
  }
  if (!any(sub("\\s*\\(.*", "", deps) == "jlbind")) {
    set(
      "Imports",
      if (is.na(imports)) "jlbind" else paste0(imports, ",\n    jlbind")
    )
  }
  if (!"SystemRequirements" %in% fields) {
    set(
      "SystemRequirements",
      "Julia (>= 1.13)"
    )
  }
  if (changed) {
    write.dcf(desc, file, keep.white = colnames(desc))
  }
}

# The git revision of jlbind whose JLBind a binding package's [sources] names,
# so Pkg (and editors) can resolve the binding package's environment: the
# release tag of the installed jlbind, or main for a development version.
# Builds develop the installed copy of JLBind regardless.
.jlbind_rev <- function(version = utils::packageVersion("jlbind")) {
  version <- unclass(package_version(version))[[1L]]
  if (length(version) > 3L && version[[4L]] >= 9000L) {
    "main"
  } else {
    paste0("v", paste(version[1:3], collapse = "."))
  }
}

.template <- function(name) {
  readLines(system.file("templates", name, package = "jlbind"), warn = FALSE)
}

.fill <- function(lines, vars) {
  for (key in names(vars)) {
    lines <- gsub(paste0("{{", key, "}}"), vars[[key]], lines, fixed = TRUE)
  }
  lines
}

.write_template <- function(name, to, vars) {
  writeLines(.fill(.template(name), vars), to)
}

# Appends `line` to the file unless it has it, creating the file if needed.
.add_line <- function(file, line) {
  lines <- if (file.exists(file)) readLines(file, warn = FALSE)
  if (!line %in% lines) {
    writeLines(c(lines, line), file)
  }
  invisible(NULL)
}

# A name-based (version 3) UUID for a binding package. Module names must be
# unique across clients anyway, so deriving the UUID from the name needs no
# Julia and no random numbers.
.uuid3 <- function(module) {
  f <- tempfile()
  on.exit(unlink(f))
  writeBin(charToRaw(paste0("jlbind:", module)), f)
  hex <- strsplit(unname(tools::md5sum(f)), "")[[1L]]
  hex[13L] <- "3"
  variant <- bitwOr(bitwAnd(strtoi(hex[17L], 16L), 3L), 8L)
  hex[17L] <- sprintf("%x", variant)
  s <- paste(hex, collapse = "")
  paste(
    substr(s, 1L, 8L),
    substr(s, 9L, 12L),
    substr(s, 13L, 16L),
    substr(s, 17L, 20L),
    substr(s, 21L, 32L),
    sep = "-"
  )
}
