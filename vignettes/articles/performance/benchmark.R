# Benchmarks behind vignettes/articles/performance.qmd, comparing jlbind with
# JuliaCall and JuliaConnectoR on the functions of the benchjl client next to
# this script.
#
# Needs benchjl installed (R CMD INSTALL vignettes/articles/performance/benchjl),
# a jlbind library built from it (JLBIND_LIBRARY, or install_library()), and
# JuliaCall, JuliaConnectoR, bench and callr. Each interface runs in fresh R
# processes, since jlbind and JuliaCall can't share one. Run from the package root:
#
#   Rscript vignettes/articles/performance/benchmark.R
#
# and commit the CSV files it writes next to this script.

out_dir <- "vignettes/articles/performance"
startup_reps <- 10
sizes <- 10^(1:7)

# The Julia definitions JuliaCall and JuliaConnectoR evaluate, matching benchjl.
julia_defs <- '
greet(name::String) = "Hello, " * name * "!"
shift(x::Vector{Float64}, by::Float64) = x .+ by
'

# Code for each interface: `setup` loads it and returns R functions `greet`
# and `shift`, run in a fresh process.
interfaces <- list(
  jlbind = function(defs) {
    library(benchjl)
    list(greet = greet, shift = shift)
  },
  JuliaCall = function(defs) {
    library(JuliaCall)
    julia_setup(installJulia = FALSE, verbose = FALSE)
    # julia_command() takes one expression at a time
    for (def in strsplit(trimws(defs), "\n")[[1]]) {
      julia_command(def)
    }
    list(
      greet = function(name) julia_call("greet", name),
      shift = function(x, by) julia_call("shift", x, by)
    )
  },
  JuliaConnectoR = function(defs) {
    library(JuliaConnectoR)
    juliaEval(defs)
    list(greet = juliaFun("greet"), shift = juliaFun("shift"))
  }
)

# Time from loading the interface to the first result, in a fresh R process
# (R's own startup excluded).
startup <- function(setup, defs) {
  start <- bench::hires_time()
  f <- suppressMessages(setup(defs))
  f$greet("world")
  as.numeric(bench::hires_time() - start)
}

# Per-call times, after a first call to each function.
calls <- function(setup, defs, sizes) {
  f <- suppressMessages(setup(defs))
  f$greet("world")
  f$shift(c(1, 2), 1)
  res <- list(bench::mark(f$greet("world"), min_time = 1))
  for (n in sizes) {
    x <- runif(n)
    stopifnot(all.equal(f$shift(x, 1), x + 1))
    res[[length(res) + 1]] <- bench::mark(
      f$shift(x, 1),
      min_time = 1,
      max_iterations = 1000,
      check = FALSE
    )
  }
  data.frame(
    task = c("greet", rep("shift", length(sizes))),
    n = c(NA, sizes),
    median = vapply(res, \(r) as.numeric(r$median), numeric(1)),
    iterations = vapply(res, \(r) r$n_itr, numeric(1))
  )
}

startup_times <- do.call(
  rbind,
  lapply(names(interfaces), function(name) {
    secs <- vapply(
      seq_len(startup_reps),
      function(i) {
        callr::r(startup, list(interfaces[[name]], julia_defs))
      },
      numeric(1)
    )
    data.frame(interface = name, rep = seq_along(secs), seconds = secs)
  })
)

call_times <- do.call(
  rbind,
  lapply(names(interfaces), function(name) {
    res <- callr::r(calls, list(interfaces[[name]], julia_defs, sizes))
    cbind(interface = name, res)
  })
)

versions <- callr::r(function() {
  julia <- Sys.getenv("JULIA", "julia")
  pkgs <- c("jlbind", "JuliaCall", "JuliaConnectoR")
  data.frame(
    item = c("R", "Julia", "CPU", pkgs, "JuliaCall commit"),
    value = c(
      as.character(getRversion()),
      sub("^julia version ", "", system2(julia, "--version", stdout = TRUE)),
      tryCatch(
        sub(
          ".*:\\s*",
          "",
          grep("model name", readLines("/proc/cpuinfo"), value = TRUE)[1]
        ),
        error = function(e) NA
      ),
      vapply(pkgs, \(p) as.character(packageVersion(p)), ""),
      substr(packageDescription("JuliaCall")$RemoteSha %||% NA, 1, 7)
    )
  )
})

write.csv(startup_times, file.path(out_dir, "startup.csv"), row.names = FALSE)
write.csv(call_times, file.path(out_dir, "calls.csv"), row.names = FALSE)
write.csv(versions, file.path(out_dir, "versions.csv"), row.names = FALSE)
