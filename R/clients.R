# A client package declares itself with the DESCRIPTION field `Config/jlbind`,
# whose value is the directory of its binding package (a Julia package),
# relative to the installed package (`inst/` in the sources), conventionally
# `julia`. A client whose Julia code cannot be compiled with `--trim=safe`
# sets `Config/jlbind/trim: false`, which turns trimming off for the whole
# library, since all clients are compiled into one.
.field <- "Config/jlbind"
.trim_field <- "Config/jlbind/trim"

#' List the packages that use jlbind
#'
#' Lists the installed packages that [install_library()] will compile. A package
#' uses jlbind if its `DESCRIPTION` has a `Config/jlbind` field. If a package is
#' installed in more than one library, the copy that [library()] would load is
#' the one listed.
#'
#' @param lib.loc Library paths to search. Defaults to [.libPaths()].
#'
#' @return A data frame with one row per package and the columns `package`,
#'   `version`, `module` (the name of its Julia binding package), `path` (where
#'   the binding package is), `trim` (`FALSE` if it sets
#'   `Config/jlbind/trim: false`) and `hash` (a hash of the binding package's
#'   files, which the library records to tell when it is out of date).
#' @export
#' @examples
#' jlbind_clients()
jlbind_clients <- function(lib.loc = NULL) {
  pkgs <- utils::installed.packages(lib.loc = lib.loc, fields = .field)
  pkgs <- pkgs[!is.na(pkgs[, .field]), , drop = FALSE]
  pkgs <- pkgs[!duplicated(pkgs[, "Package"]), , drop = FALSE]
  paths <- file.path(pkgs[, "LibPath"], pkgs[, "Package"])
  .client_table(lapply(paths, .client_info))
}

# The client in `path`: an installed package, or the sources of one.
.client_info <- function(path) {
  file <- file.path(path, "DESCRIPTION")
  if (!file.exists(file)) {
    stop("No package found in ", path, ".", call. = FALSE)
  }
  desc <- read.dcf(file, fields = c("Package", "Version", .field, .trim_field))
  if (is.na(desc[, .field])) {
    stop(
      "The package in ",
      path,
      " does not use jlbind: its DESCRIPTION has no `",
      .field,
      "` field.",
      call. = FALSE
    )
  }
  installed <- dir.exists(file.path(path, "Meta"))
  root <- normalizePath(path)
  if (!installed) {
    root <- file.path(root, "inst")
  }
  binding <- file.path(root, trimws(desc[, .field]))
  list(
    package = unname(desc[, "Package"]),
    version = unname(desc[, "Version"]),
    module = .binding_name(binding),
    path = binding,
    trim = .parse_trim(desc[, .trim_field], desc[, "Package"]),
    hash = .binding_hash(binding)
  )
}

# A hash of the files of the binding package in `dir`. The library records it
# for each client, so install_library() rebuilds it when a client is
# reinstalled with changed Julia code but the same version.
.binding_hash <- function(dir) {
  files <- sort(list.files(dir, recursive = TRUE), method = "radix")
  record <- tempfile()
  on.exit(unlink(record))
  writeLines(paste(files, tools::md5sum(file.path(dir, files))), record)
  unname(tools::md5sum(record))
}

# The `Config/jlbind/trim` field: trimmed unless it says otherwise.
.parse_trim <- function(value, package) {
  if (is.na(value)) {
    return(TRUE)
  }
  value <- tolower(trimws(value))
  if (value %in% c("true", "yes")) {
    return(TRUE)
  }
  if (value %in% c("false", "no")) {
    return(FALSE)
  }
  stop(
    "The `",
    .trim_field,
    "` field of ",
    package,
    " must be true or false, not \"",
    value,
    "\".",
    call. = FALSE
  )
}

.client_table <- function(infos) {
  col <- function(name) vapply(infos, `[[`, "", name)
  data.frame(
    package = col("package"),
    version = col("version"),
    module = col("module"),
    path = col("path"),
    trim = vapply(infos, `[[`, TRUE, "trim"),
    hash = col("hash"),
    stringsAsFactors = FALSE
  )
}

# The name of the Julia package in `dir`, from its Project.toml.
.binding_name <- function(dir) {
  file <- file.path(dir, "Project.toml")
  if (!file.exists(file)) {
    stop("No Julia package (Project.toml) found in ", dir, ".", call. = FALSE)
  }
  lines <- readLines(file, warn = FALSE)
  m <- regmatches(lines, regexec('^\\s*name\\s*=\\s*"([^"]+)"', lines))
  m <- Filter(length, m)
  if (length(m) == 0L) {
    stop("The Project.toml in ", dir, " has no `name`.", call. = FALSE)
  }
  m[[1L]][[2L]]
}
