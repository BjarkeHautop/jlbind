# The julia binary to build with, checked to be at least 1.14.
.find_julia <- function(julia = NULL) {
  if (is.null(julia)) {
    julia <- Sys.getenv("JULIA", unset = "")
    if (!nzchar(julia)) {
      julia <- unname(Sys.which("julia"))
    }
  }
  if (!nzchar(julia)) {
    stop(
      "Julia was not found. Install Julia (>= 1.14), see ",
      "https://julialang.org/install/, or pass the path of a julia binary ",
      "as `julia` (or set the JULIA environment variable).",
      call. = FALSE
    )
  }
  version <- .julia_version(julia)
  if (is.na(version)) {
    stop("Could not run `", julia, " --version`.", call. = FALSE)
  }
  if (version < "1.14") {
    stop(
      "jlbind needs Julia >= 1.14, but ",
      julia,
      " is version ",
      version,
      ". With juliaup: `juliaup add nightly`, then pass its julia binary as ",
      "`julia`.",
      call. = FALSE
    )
  }
  julia
}

.julia_version <- function(julia) {
  output <- suppressWarnings(tryCatch(
    system2(julia, "--version", stdout = TRUE, stderr = FALSE),
    error = function(e) character()
  ))
  version <- regmatches(output, regexpr("[0-9]+\\.[0-9]+\\.[0-9]+", output))
  if (length(version) == 0L) {
    return(NA)
  }
  package_version(version[[1L]])
}

# Runs `julia --startup-file=no <args>`, with its output going to the console.
.run_julia <- function(julia, args) {
  # R puts its own library directories on LD_LIBRARY_PATH, which overrides
  # the RUNPATH of Julia's bundled tools and makes e.g. Pkg's zstd load the
  # system libzstd instead of Julia's.
  ld_path <- Sys.getenv("LD_LIBRARY_PATH", unset = NA)
  if (!is.na(ld_path)) {
    Sys.unsetenv("LD_LIBRARY_PATH")
    on.exit(Sys.setenv(LD_LIBRARY_PATH = ld_path), add = TRUE)
  }
  system2(julia, c("--startup-file=no", args))
}
