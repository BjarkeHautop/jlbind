#' Set up a package to use jlbind
#'
#' Adds what a package needs to call Julia code through jlbind.
#'
#' * A Julia binding package in `inst/<dir>`, with one example function,
#'   `hello()`. An existing binding package is left alone.
#' * The C code that registers the package's routines: `src/jlbind.c` and
#'   `src/entrypoints.h` (written by [update_entrypoints()]).
#' * `R/jlbind.R`, with an `.onLoad()` that calls [bind_client()], and the
#'   roxygen tag for `useDynLib()`. If the package already has an `.onLoad()`,
#'   add `jlbind::bind_client(pkgname)` to it yourself.
#' * The `Config/jlbind` and `Imports: jlbind` fields in `DESCRIPTION`.
#' * `.jlbind/`, where [build_library()] writes a library for development, in
#'   `.Rbuildignore` and `.gitignore`.
#'
#' It's safe to run again. Afterwards, call each Julia function `f` from R with
#' `.Call(C_f, ...)`.
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
    vars <- list(package = pkg, module = module, uuid = .uuid4())
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

  src <- file.path(path, "src")
  dir.create(src, showWarnings = FALSE)
  others <- setdiff(list.files(src, "\\.(c|cpp|cc)$"), "jlbind.c")
  for (f in others) {
    if (any(grepl("R_init_", readLines(file.path(src, f), warn = FALSE)))) {
      stop(
        "src/",
        f,
        " registers the package's routines already; jlbind's src/jlbind.c ",
        "needs to.",
        call. = FALSE
      )
    }
  }
  .write_template(
    "init.c",
    file.path(src, "jlbind.c"),
    list(package = pkg, init = gsub(".", "_", pkg, fixed = TRUE))
  )
  if (!file.exists(file.path(src, ".gitignore"))) {
    writeLines(c("*.o", "*.so", "*.dll"), file.path(src, ".gitignore"))
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
  r_code <- .fill(.template("jlbind.R"), list(package = pkg))
  if (has_onload) {
    r_code <- r_code[-grep("onLoad|jlbind::bind|^\\}", r_code)]
    message(
      "The package has an .onLoad() already: call ",
      "`jlbind::bind_client(pkgname)` from it."
    )
  }
  writeLines(r_code, file.path(r_dir, "jlbind.R"))

  ns_file <- file.path(path, "NAMESPACE")
  ns <- if (file.exists(ns_file)) {
    readLines(ns_file, warn = FALSE)
  } else {
    character()
  }
  if (any(grepl("roxygen2", ns[1L]))) {
    message("Run roxygen2::roxygenise() to add useDynLib() to the NAMESPACE.")
  } else if (!any(grepl("^useDynLib", ns))) {
    writeLines(
      c(
        ns,
        paste0("useDynLib(", pkg, ", .registration = TRUE, .fixes = \"C_\")")
      ),
      ns_file
    )
  }
  invisible(path)
}

#' Update the list of Julia functions R can call
#'
#' Finds the `@rcall` declarations in the package's Julia binding package and
#' writes them to `src/entrypoints.h`. From that, `src/jlbind.c` registers a
#' routine `C_<name>` for each one. Run this whenever you add or remove an
#' `@rcall`, or change its arguments, much like `Rcpp::compileAttributes()`.
#'
#' @param path Path to the package sources.
#'
#' @return Invisibly, a data frame of the entrypoints with the columns `name`
#'   and `nargs`.
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
#' # The package now calls it as .Call(C_add, x, y)
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
    entries <- data.frame(name = character(), nargs = integer())
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
  params <- vapply(
    entries$nargs,
    function(n) {
      if (n == 0L) {
        "(void)"
      } else {
        paste0("(", paste0("SEXP a", seq_len(n), collapse = ", "), ")")
      }
    },
    ""
  )
  args <- vapply(
    entries$nargs,
    function(n) {
      if (n == 0L) {
        "()"
      } else {
        paste0("(", paste0("a", seq_len(n), collapse = ", "), ")")
      }
    },
    ""
  )
  lines <- c(
    "/*",
    " * Generated by jlbind::update_entrypoints() from the @rcall declarations",
    paste0(" * of the binding package ", info$module, "; do not edit by hand."),
    " *",
    " * JLBIND_ENTRY(name, number of arguments, parameters, arguments): each is",
    " * registered as the .Call routine `C_<name>`, forwarding to the library's",
    " * `<JLBIND_PREFIX><name>`.",
    " */",
    "",
    paste0("#define JLBIND_PREFIX \"", info$module, "_\""),
    "",
    if (nrow(entries)) {
      c(
        "#define JLBIND_ENTRIES \\",
        paste0(
          "    JLBIND_ENTRY(",
          entries$name,
          ", ",
          entries$nargs,
          ", ",
          params,
          ", ",
          args,
          ")",
          c(rep(" \\", nrow(entries) - 1L), "")
        )
      )
    } else {
      "#define JLBIND_ENTRIES"
    }
  )
  out <- file.path(path, "src", "entrypoints.h")
  old <- if (file.exists(out)) readLines(out, warn = FALSE)
  if (!identical(old, lines)) {
    dir.create(dirname(out), showWarnings = FALSE)
    writeLines(lines, out)
    message("Wrote ", out, " (", nrow(entries), " entrypoints).")
  }
  invisible(entries)
}

# The `@rcall` declarations in Julia source `src`: a data frame of each
# entrypoint's name and number of arguments.
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
  nargs <- vapply(open, function(i) .count_args(ch, i, file), 1L)
  data.frame(name = names, nargs = nargs)
}

# The number of arguments in the call whose opening parenthesis is `ch[i]`.
.count_args <- function(ch, i, file) {
  depth <- 0L
  commas <- 0L
  content <- FALSE
  for (j in seq.int(i, length(ch))) {
    c <- ch[[j]]
    if (c %in% c("(", "[", "{")) {
      depth <- depth + 1L
      if (depth == 1L) next
    } else if (c %in% c(")", "]", "}")) {
      depth <- depth - 1L
      if (depth == 0L) {
        return(commas + content)
      }
    } else if (depth == 1L && c == ",") {
      # A trailing comma does not start another argument.
      commas <- commas + content
      content <- FALSE
      next
    } else if (depth == 1L && c == ";") {
      stop(
        "@rcall in ",
        file,
        ": keyword arguments are not supported.",
        call. = FALSE
      )
    }
    if (depth >= 1L && !grepl("\\s", c)) {
      content <- TRUE
    }
  }
  stop("@rcall in ", file, ": unbalanced parentheses.", call. = FALSE)
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
      "Julia (>= 1.13), needed to build the compiled library with\n    jlbind::install_library()"
    )
  }
  if (changed) {
    write.dcf(desc, file, keep.white = colnames(desc))
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

# A random (version 4) UUID, leaving the session's random numbers as they were.
# Appends `line` to the file unless it has it, creating the file if needed.
.add_line <- function(file, line) {
  lines <- if (file.exists(file)) readLines(file, warn = FALSE)
  if (!line %in% lines) {
    writeLines(c(lines, line), file)
  }
  invisible(NULL)
}

.uuid4 <- function() {
  if (exists(".Random.seed", globalenv())) {
    seed <- get(".Random.seed", globalenv())
    on.exit(assign(".Random.seed", seed, globalenv()))
  }
  set.seed(NULL)
  hex <- sample(c(0:9, letters[1:6]), 32L, replace = TRUE)
  hex[13L] <- "4"
  hex[17L] <- sample(c("8", "9", "a", "b"), 1L)
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
