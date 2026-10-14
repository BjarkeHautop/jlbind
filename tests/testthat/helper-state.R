# Restores jlbind's runtime state (.state) when `env` ends, so a test can fake
# a loaded library or bound clients.
local_state <- function(env = parent.frame()) {
  old <- as.list(.state, all.names = TRUE)
  withr::defer(
    {
      rm(list = ls(.state, all.names = TRUE), envir = .state)
      list2env(old, envir = .state)
    },
    envir = env
  )
  invisible(.state)
}

# A .client_table() of clients that need not exist.
fake_clients <- function(package = c("a", "b"), module = toupper(package)) {
  data.frame(
    package = package,
    version = rep("1.0", length(package)),
    module = module,
    path = file.path("bindings", package),
    trim = rep(TRUE, length(package)),
    stringsAsFactors = FALSE
  )
}
